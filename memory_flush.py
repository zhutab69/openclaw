"""Pre-shutdown memory flush: extract key info from active sessions and append to daily memory.

Called by OpenClaw.ps1 Cleanup function before killing processes.
Reads the current main session's recent messages and writes a summary
to workspace/memory/YYYY-MM-DD.md so startupContext can load it next time.
"""
import json, os, time
from datetime import datetime

HOME = os.environ["USERPROFILE"]
SESSIONS_DIR = os.path.join(HOME, ".openclaw", "agents", "main", "sessions")
SESSIONS_JSON = os.path.join(SESSIONS_DIR, "sessions.json")
MEMORY_DIR = os.path.join(HOME, ".openclaw", "workspace", "memory")

def get_active_session_file():
    """Find the current main session file."""
    if not os.path.isfile(SESSIONS_JSON):
        return None
    try:
        with open(SESSIONS_JSON, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
        entry = data.get("agent:main:main", {})
        session_id = entry.get("sessionId", "")
        if not session_id:
            return None
        session_file = os.path.join(SESSIONS_DIR, f"{session_id}.jsonl")
        if os.path.isfile(session_file):
            return session_file
    except Exception:
        pass
    return None


def extract_recent_summary(session_file, max_lines=50):
    """Extract the last N lines from session file and build a summary."""
    try:
        with open(session_file, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except Exception:
        return None

    if not lines:
        return None

    # Parse recent messages (last max_lines)
    recent = lines[-max_lines:]
    summaries = []

    for line in recent:
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            msg_type = obj.get("type", "")
            if msg_type != "message":
                continue
            message = obj.get("message", {})
            role = message.get("role", "")
            content = message.get("content", "")

            # Extract text content
            if isinstance(content, list):
                text_parts = []
                for part in content:
                    if isinstance(part, dict) and part.get("type") == "text":
                        text_parts.append(part.get("text", "")[:200])
                text = " ".join(text_parts)
            elif isinstance(content, str):
                text = content[:200]
            else:
                continue

            if not text or len(text) < 10:
                continue

            # Only include user and assistant messages
            if role in ("user", "assistant"):
                prefix = "👤" if role == "user" else "🤖"
                summaries.append(f"{prefix} {text[:150]}")
        except (json.JSONDecodeError, KeyError):
            continue

    return summaries[-20:]  # Keep last 20 meaningful messages


def flush_to_daily_memory(summaries):
    """Append session summary to today's daily memory file."""
    if not summaries:
        return False

    os.makedirs(MEMORY_DIR, exist_ok=True)
    today = datetime.now().strftime("%Y-%m-%d")
    memory_file = os.path.join(MEMORY_DIR, f"{today}.md")

    timestamp = datetime.now().strftime("%H:%M:%S")
    section = f"\n\n## Session Flush ({timestamp})\n\n"
    section += "Recent conversation before shutdown:\n\n"
    for s in summaries:
        section += f"- {s}\n"

    try:
        with open(memory_file, "a", encoding="utf-8") as f:
            f.write(section)
        return True
    except Exception:
        return False


def main():
    session_file = get_active_session_file()
    if not session_file:
        print("[memory-flush] no active session found, skipping")
        return

    summaries = extract_recent_summary(session_file)
    if not summaries:
        print("[memory-flush] no recent messages to flush")
        return

    if flush_to_daily_memory(summaries):
        print(f"[memory-flush] flushed {len(summaries)} messages to daily memory")
    else:
        print("[memory-flush] failed to write memory file")


if __name__ == "__main__":
    main()
