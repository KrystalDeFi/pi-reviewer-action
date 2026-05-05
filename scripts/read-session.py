#!/usr/bin/env python3
"""Pretty-print a pi session JSONL file to stdout.

Usage: python3 assets/read-session.py <path-to-session.jsonl>
"""

import json
import sys
import textwrap
from pathlib import Path

RESET = "\033[0m"
BOLD = "\033[1m"
DIM = "\033[2m"
CYAN = "\033[36m"
YELLOW = "\033[33m"
GREEN = "\033[32m"
RED = "\033[31m"
MAGENTA = "\033[35m"
BLUE = "\033[34m"


def wrap(text: str, indent: int = 4, width: int = 120) -> str:
    prefix = " " * indent
    return textwrap.indent(text.rstrip(), prefix)


def print_section(label: str, color: str, body: str) -> None:
    print(f"\n{color}{BOLD}{label}{RESET}")
    print(wrap(body))


def render_content(blocks: list | str) -> None:
    if isinstance(blocks, str):
        print(wrap(blocks))
        return

    for block in blocks:
        t = block.get("type", "")

        if t == "text":
            text = block.get("text", "").strip()
            if text:
                print(wrap(text))

        elif t == "thinking":
            thinking = block.get("thinking", "").strip()
            if thinking:
                print(f"\n  {DIM}┌─ thinking {'─'*60}{RESET}")
                print(wrap(thinking))
                print(f"  {DIM}└{'─'*68}{RESET}")

        elif t == "toolCall":
            name = block.get("name", "")
            args = block.get("arguments", {})
            args_str = json.dumps(args, indent=2)
            print(f"\n  {CYAN}▶ {name}{RESET}")
            print(wrap(args_str, indent=6))

        else:
            # Unknown block — dump raw for transparency
            print(wrap(json.dumps(block)))


def main() -> None:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <session.jsonl>", file=sys.stderr)
        sys.exit(1)

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"File not found: {path}", file=sys.stderr)
        sys.exit(1)

    lines = path.read_text().splitlines()
    turn = 0

    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue

        etype = entry.get("type")

        if etype == "session":
            ts = entry.get("timestamp", "")
            cwd = entry.get("cwd", "")
            sid = entry.get("id", "")
            print(f"{BOLD}{'='*80}{RESET}")
            print(f"{BOLD}Session {sid}{RESET}")
            print(f"  time : {ts}")
            print(f"  cwd  : {cwd}")
            print(f"{BOLD}{'='*80}{RESET}")

        elif etype == "model_change":
            provider = entry.get("provider", "")
            model = entry.get("modelId", "")
            print(f"\n{DIM}[model: {provider}/{model}]{RESET}")

        elif etype == "thinking_level_change":
            level = entry.get("thinkingLevel", "")
            print(f"{DIM}[thinking: {level}]{RESET}")

        elif etype == "message":
            msg = entry.get("message", {})
            role = msg.get("role", "")
            content = msg.get("content", [])

            if role == "user":
                turn += 1
                print(f"\n{GREEN}{BOLD}{'─'*80}{RESET}")
                print(f"{GREEN}{BOLD}▌ USER  (turn {turn}){RESET}")
                print(f"{GREEN}{BOLD}{'─'*80}{RESET}")
                render_content(content)

            elif role == "assistant":
                usage = entry.get("message", {})
                model = entry.get("message", {}).get("model", "")
                cost_info = ""
                if "usage" in msg:
                    u = msg["usage"]
                    cost = u.get("cost", {})
                    total = cost.get("total", 0) if isinstance(cost, dict) else 0
                    tokens = u.get("totalTokens", 0)
                    cost_info = f"  {DIM}({tokens} tokens, ${total:.4f}){RESET}"

                print(f"\n{BLUE}{BOLD}{'─'*80}{RESET}")
                print(f"{BLUE}{BOLD}▌ ASSISTANT  (turn {turn}){RESET}{cost_info}")
                print(f"{BLUE}{BOLD}{'─'*80}{RESET}")
                render_content(content)

            elif role == "toolResult":
                tool_name = msg.get("toolName", "")
                is_error = msg.get("isError", False)
                color = RED if is_error else YELLOW
                status = "ERROR" if is_error else "ok"
                print(f"\n  {color}◀ {tool_name} [{status}]{RESET}")
                render_content(content)


if __name__ == "__main__":
    main()
