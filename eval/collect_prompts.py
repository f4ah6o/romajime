#!/usr/bin/env python3
"""Collect Japanese sentences the user actually wrote from Claude Code and
Codex prompt history, for use as a conversion-accuracy eval corpus.

Additional sources: drop ChatGPT or claude.ai data-export JSON files (e.g.
conversations.json) into eval/sources/ — formats are auto-detected.

Output (one sentence per line) goes to eval/corpus_ja.txt — private data,
must stay gitignored (as is eval/sources/).
"""

import json
import re
import sys
from pathlib import Path

HOME = Path.home()
OUT = Path(__file__).parent / "corpus_ja.txt"
SOURCES_DIR = Path(__file__).parent / "sources"

JAPANESE = re.compile(r"[぀-ヿ一-鿿]")
KANA = re.compile(r"[぀-ヿ]")
URL = re.compile(r"https?://\S+")
CODE_FENCE = re.compile(r"```.*?```", re.S)
INLINE_CODE = re.compile(r"`[^`]*`")
TAG = re.compile(r"<[^>]+>")
SENTENCE_SPLIT = re.compile(r"(?<=[。!?!?])")


def clean(text):
    text = CODE_FENCE.sub(" ", text)
    text = INLINE_CODE.sub(" ", text)
    text = TAG.sub(" ", text)
    text = URL.sub(" ", text)
    return text


def sentences(text):
    for line in clean(text).splitlines():
        line = line.strip()
        if not line or line.startswith(("/", "#", "$", "[Request interrupted")):
            continue
        # strip list markers
        line = re.sub(r"^(\d+[.)]\s*|[-*+]\s+)", "", line)
        for sentence in SENTENCE_SPLIT.split(line):
            sentence = sentence.strip()
            if not (4 <= len(sentence) <= 80):
                continue
            if not JAPANESE.search(sentence) or not KANA.search(sentence):
                continue
            # mostly-Japanese sentences only: skip lines dominated by paths/code
            ascii_ratio = sum(c.isascii() for c in sentence) / len(sentence)
            if ascii_ratio > 0.5:
                continue
            yield sentence


def claude_code_texts():
    for path in (HOME / ".claude" / "projects").glob("*/*.jsonl"):
        try:
            lines = path.read_text(encoding="utf-8", errors="ignore").splitlines()
        except OSError:
            continue
        for line in lines:
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("type") != "user":
                continue
            content = entry.get("message", {}).get("content")
            if isinstance(content, str):
                yield content
            elif isinstance(content, list):
                for part in content:
                    if isinstance(part, dict) and part.get("type") == "text":
                        yield part.get("text", "")


def codex_texts():
    path = HOME / ".codex" / "history.jsonl"
    if not path.exists():
        return
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        text = entry.get("text")
        if isinstance(text, str):
            yield text


def chat_export_texts():
    """ChatGPT and claude.ai data exports dropped into eval/sources/."""
    if not SOURCES_DIR.is_dir():
        return
    for path in SOURCES_DIR.glob("**/*.json"):
        try:
            data = json.loads(path.read_text(encoding="utf-8", errors="ignore"))
        except (OSError, json.JSONDecodeError):
            print(f"warning: skipping unreadable {path}", file=sys.stderr)
            continue
        count = 0
        for text in parse_chat_export(data):
            count += 1
            yield text
        print(f"{path.name}: {count} user messages", file=sys.stderr)


def parse_chat_export(data):
    conversations = data if isinstance(data, list) else [data]
    for convo in conversations:
        if not isinstance(convo, dict):
            continue
        # ChatGPT export: {"mapping": {id: {"message": {"author": {"role": ...},
        #                                   "content": {"parts": [...]}}}}}
        mapping = convo.get("mapping")
        if isinstance(mapping, dict):
            for node in mapping.values():
                message = (node or {}).get("message") or {}
                if (message.get("author") or {}).get("role") != "user":
                    continue
                for part in (message.get("content") or {}).get("parts") or []:
                    if isinstance(part, str):
                        yield part
        # claude.ai export: {"chat_messages": [{"sender": "human", "text": ...,
        #                                       "content": [{"type": "text", ...}]}]}
        for message in convo.get("chat_messages") or []:
            if not isinstance(message, dict) or message.get("sender") != "human":
                continue
            if isinstance(message.get("text"), str):
                yield message["text"]
            for part in message.get("content") or []:
                if isinstance(part, dict) and part.get("type") == "text":
                    yield part.get("text", "")


def main():
    seen = set()
    corpus = []
    for text in list(claude_code_texts()) + list(codex_texts()) + list(chat_export_texts()):
        for sentence in sentences(text):
            if sentence not in seen:
                seen.add(sentence)
                corpus.append(sentence)
    OUT.write_text("\n".join(corpus) + "\n", encoding="utf-8")
    print(f"collected {len(corpus)} sentences -> {OUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
