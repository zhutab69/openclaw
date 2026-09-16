#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Skill Health Analyzer  (observe + diagnose layers of the skill-governance loop)

Reads ONLY structured trace fields (no fragile systemPrompt regex):
  - trace.metadata.data.skills.entries          -> structured skill roster (id/name/available/disableModelInvocation)
  - trace.metadata.data.prompting.systemPromptReport.skills -> exact per-skill blockChars
  - read toolCall on *.SKILL.md (in *.jsonl)    -> genuine load intent (dir name -> mapped to frontmatter name)
  - session.ended.data.status / model.completed -> outcome signal per run

Join key = frontmatter `name` (verified == config skills.entries.<KEY>).
Outputs a per-skill health profile + a machine-readable JSON report.
"""
import os, re, json, sys, glob, time
from collections import Counter, defaultdict
sys.stdout.reconfigure(encoding='utf-8')

HOME = os.path.expanduser("~")
STATE = os.path.join(HOME, ".openclaw")
AGENTS_DIR = os.path.join(STATE, "agents")
CONFIG_PATH = os.path.join(STATE, "openclaw.json")
SKILL_DIRS = [
    (os.path.join(STATE, "skills"), "user"),
    (os.path.join(STATE, "plugin-skills"), "plugin"),
    (r"D:\Kiro\testopenclaw\node-v22.22.1-win-x64\node_modules\openclaw\skills", "bundled"),
]
TOOL_MAP_PATH = os.path.join(STATE, "workspace", "skill-tool-map.json")
NOW = time.time()
RECENT_DAYS = 14
RECENT_CUTOFF = NOW - RECENT_DAYS*86400

# ---------- 0. Load tool-direct-use map ----------
tool_direct_skills = set()
try:
    with open(TOOL_MAP_PATH, encoding='utf-8') as f:
        tm = json.load(f)
    tool_direct_skills = set(tm.get("tool_direct_skills", {}).keys())
except Exception:
    pass  # map missing is non-fatal

# ---------- 1. Build dir -> frontmatter name map (the join-key foundation) ----------
def parse_frontmatter(path):
    name = slug = skillkey = desc = None
    try:
        with open(path, encoding='utf-8', errors='ignore') as f:
            txt = f.read(4000)
    except Exception:
        return {}
    m = re.search(r'^---\s*\n(.*?)\n---', txt, re.S)
    block = m.group(1) if m else txt
    for line in block.splitlines():
        for key, var in (("name","name"),("slug","slug"),("skillKey","skillKey"),("description","description")):
            mm = re.match(r'\s*'+key+r'\s*:\s*(.+?)\s*$', line)
            if mm:
                val = mm.group(1).strip()
                if key=="name" and name is None: name=val
                elif key=="slug" and slug is None: slug=val
                elif key=="skillKey" and skillkey is None: skillkey=val
                elif key=="description" and desc is None: desc=val
    resolved = skillkey or name
    return {"name": name, "slug": slug, "skillKey": skillkey, "resolved_key": resolved, "description": desc}

disk_skills = {}     # dir_name -> meta
name_to_dir = {}     # resolved_key -> dir_name
for base, src in SKILL_DIRS:
    if not os.path.isdir(base): continue
    for entry in os.listdir(base):
        sf = os.path.join(base, entry, "SKILL.md")
        if os.path.isfile(sf):
            meta = parse_frontmatter(sf)
            meta["dir"] = entry
            meta["src"] = src
            disk_skills[entry] = meta
            rk = meta.get("resolved_key") or entry
            name_to_dir[rk] = entry

dir_to_name = {d: (m.get("resolved_key") or d) for d,m in disk_skills.items()}

# ---------- 2. Load config: which keys are disabled, and is the disable EFFECTIVE ----------
cfg = {}
try:
    cfg = json.load(open(CONFIG_PATH, encoding='utf-8'))
except Exception as e:
    print(f"WARN: cannot read config: {e}", file=sys.stderr)
entries_cfg = cfg.get("skills", {}).get("entries", {}) or {}
disabled_keys = {k for k,v in entries_cfg.items() if isinstance(v,dict) and v.get("enabled") is False}

# disable effectiveness: a disabled key is effective only if some on-disk skill resolves to it
valid_resolved = set(dir_to_name.values())
fake_disables = {k for k in disabled_keys if k not in valid_resolved and k in disk_skills}
# (k in disk_skills means a DIR exists by that name but its real resolved_key differs)

# ---------- 3. Walk all traces: roster, char cost, injections, outcomes ----------
roster = {}                  # name -> structured entry (from trace.metadata)
inject_count = Counter()     # name -> times injected into a prompt
block_chars = {}             # name -> latest blockChars
run_outcomes = []            # list of dicts per run
tools_schema_chars = []
prompt_skill_chars = []

def iter_trace_files():
    for agent in os.listdir(AGENTS_DIR) if os.path.isdir(AGENTS_DIR) else []:
        sd = os.path.join(AGENTS_DIR, agent, "sessions")
        if not os.path.isdir(sd): continue
        for fp in glob.glob(os.path.join(sd, "*.trajectory.jsonl")):
            yield agent, fp

for agent, fp in iter_trace_files():
    try:
        with open(fp, encoding='utf-8', errors='ignore') as f:
            for line in f:
                if '"traceSchema"' not in line: continue
                try:
                    o = json.loads(line)
                except Exception:
                    continue
                t = o.get("type")
                data = o.get("data", {})
                if t == "trace.metadata":
                    sk = data.get("skills", {})
                    for e in sk.get("entries", []) or []:
                        nm = e.get("name")
                        if nm and nm not in roster:
                            roster[nm] = {
                                "id": e.get("id"), "name": nm,
                                "available": e.get("available"),
                                "disableModelInvocation": e.get("disableModelInvocation"),
                                "source": e.get("source"),
                            }
                    rep = data.get("prompting", {}).get("systemPromptReport", {})
                    if isinstance(rep, dict):
                        srep = rep.get("skills", {})
                        if isinstance(srep, dict):
                            for se in srep.get("entries", []) or []:
                                if se.get("name"):
                                    block_chars[se["name"]] = se.get("blockChars")
                                    inject_count[se["name"]] += 1
                            if srep.get("promptChars"):
                                prompt_skill_chars.append(srep["promptChars"])
                        trep = rep.get("tools", {})
                        if isinstance(trep, dict) and trep.get("schemaChars"):
                            tools_schema_chars.append(trep["schemaChars"])
                elif t == "session.ended":
                    run_outcomes.append({
                        "agent": agent,
                        "ts": o.get("ts"),
                        "status": data.get("status"),
                        "aborted": data.get("aborted"),
                        "timedOut": data.get("timedOut"),
                    })
    except Exception:
        continue

# ---------- 4. Mine genuine skill LOADS from conversation jsonl (read toolCall) ----------
skill_path_re = re.compile(r'([A-Za-z0-9_\-\.\+ ]+)[\\/]SKILL\.md', re.I)
load_count = Counter()        # name -> genuine read loads (mapped to frontmatter name)
load_recent = Counter()       # last RECENT_DAYS
load_by_agent = defaultdict(Counter)

def iter_convo_files():
    for agent in os.listdir(AGENTS_DIR) if os.path.isdir(AGENTS_DIR) else []:
        sd = os.path.join(AGENTS_DIR, agent, "sessions")
        if not os.path.isdir(sd): continue
        for fp in glob.glob(os.path.join(sd, "*.jsonl")) + glob.glob(os.path.join(sd, "*.jsonl.deleted*")):
            if fp.endswith(".trajectory.jsonl"): continue
            yield agent, fp

for agent, fp in iter_convo_files():
    try:
        with open(fp, encoding='utf-8', errors='ignore') as f:
            for line in f:
                if 'SKILL.md' not in line or '"toolCall"' not in line: continue
                try:
                    obj = json.loads(line)
                except Exception:
                    continue
                ts_str = obj.get("timestamp") or obj.get("ts")
                # collect candidate toolCall dicts
                cands = []
                msg = obj.get("message", {})
                if isinstance(msg, dict) and isinstance(msg.get("content"), list):
                    cands.extend(msg["content"])
                cands.append(obj)
                for c in cands:
                    if not isinstance(c, dict): continue
                    if c.get("type") == "toolCall" and c.get("name") == "read":
                        args = c.get("arguments") or {}
                        pth = str(args.get("path",""))
                        if "SKILL.md" not in pth: continue
                        m = skill_path_re.search(pth)
                        if not m: continue
                        raw = m.group(1).strip()
                        # map dir name -> frontmatter name (the join)
                        nm = dir_to_name.get(raw, raw)
                        load_count[nm] += 1
                        load_by_agent[agent][nm] += 1
                        # recency
                        try:
                            tval = obj.get("timestamp")
                            if isinstance(tval,(int,float)):
                                tsec = tval/1000 if tval>1e12 else tval
                            else:
                                tsec = time.mktime(time.strptime(str(ts_str)[:19], "%Y-%m-%dT%H:%M:%S"))
                            if tsec >= RECENT_CUTOFF:
                                load_recent[nm] += 1
                        except Exception:
                            pass
    except Exception:
        continue

# ---------- 5. Compose per-skill health profile ----------
all_names = set(roster) | set(dir_to_name.values()) | set(load_count) | set(inject_count)
profiles = []
for nm in sorted(all_names):
    d = name_to_dir.get(nm)
    meta = disk_skills.get(d, {}) if d else {}
    prof = {
        "name": nm,
        "dir": d,
        "src": meta.get("src"),
        "on_disk": d is not None,
        "in_roster": nm in roster,
        "available": roster.get(nm, {}).get("available"),
        "injected": inject_count.get(nm, 0),
        "block_chars": block_chars.get(nm),
        "loads_total": load_count.get(nm, 0),
        "loads_recent": load_recent.get(nm, 0),
        "config_key_present": nm in entries_cfg,
        "config_disabled": nm in disabled_keys,
    }
    profiles.append(prof)

# health classification (improvement-oriented, NO deletion labels)
def classify(p):
    """Assign improvement-opportunity flags. Never outputs 'dead-weight' or deletion suggestions."""
    flags = []
    nm = p["name"]
    is_tool_direct = nm in tool_direct_skills

    if not p["on_disk"]:
        flags.append("phantom-config")       # config key but no skill on disk

    # Tool-direct skills: loads_total=0 is HEALTHY (they work via tool calls)
    if is_tool_direct:
        flags.append("tool-direct-healthy")
    elif p["injected"] >= 20 and p["loads_total"] == 0:
        # Injected many times but never read -> description may not trigger well
        flags.append("desc-may-need-tuning") # improvement opportunity, NOT deletion

    if p["loads_total"] > 0 and p["config_disabled"]:
        flags.append("disabled-but-was-used")
    if p["loads_recent"] == 0 and p["loads_total"] > 0:
        flags.append("dormant")              # used historically, not recently (was: stale)
    if p["loads_total"] > 0 and p["loads_recent"] > 0:
        flags.append("active")
    return flags

for p in profiles:
    p["flags"] = classify(p)

# fake disables (key mismatch)
for p in profiles:
    # a fake disable: dir exists, config has a key == dir name but resolved_key != dir name
    if p["dir"] and p["dir"] in entries_cfg and entries_cfg[p["dir"]].get("enabled") is False:
        if dir_to_name.get(p["dir"]) != p["dir"]:
            p["flags"].append("FAKE-DISABLE")

# ---------- 6. Print human report ----------
def col(s, w): 
    s = str(s)
    return s + " "*max(0, w-len(s))

print("="*90)
print("SKILL HEALTH REPORT  (data-driven, from structured traces)")
print(f"generated: {time.strftime('%Y-%m-%d %H:%M:%S')}   recent-window: {RECENT_DAYS}d")
print("="*90)

print(f"\nInventory: {len(disk_skills)} on disk | {len(roster)} in roster(injected) | {len(entries_cfg)} config entries | {len(disabled_keys)} disabled")
if tools_schema_chars:
    print(f"Tools schema: avg {sum(tools_schema_chars)//len(tools_schema_chars)} chars (the real budget hog)")
if prompt_skill_chars:
    print(f"Skills prompt: avg {sum(prompt_skill_chars)//len(prompt_skill_chars)} chars")

print(f"\n{'-'*90}")
print(col("SKILL (frontmatter name)",36)+col("inj",5)+col("load",5)+col("recent",7)+col("chars",6)+"flags")
print("-"*90)
for p in sorted(profiles, key=lambda x:(-x["loads_total"], -x["injected"])):
    flags = ",".join(p["flags"])
    mark = ""
    if "FAKE-DISABLE" in p["flags"]: mark="🔴"
    elif "desc-may-need-tuning" in p["flags"]: mark="🔧"
    elif "tool-direct-healthy" in p["flags"]: mark="🔌"
    elif "active" in p["flags"]: mark="✅"
    elif "dormant" in p["flags"]: mark="💤"
    print(col(mark+p["name"],36)+col(p["injected"],5)+col(p["loads_total"],5)+col(p["loads_recent"],7)+col(p["block_chars"] or "-",6)+flags)

# ---------- 7. Diagnostics summary (improvement-oriented) ----------
desc_tune = [p["name"] for p in profiles if "desc-may-need-tuning" in p["flags"]]
tool_healthy = [p["name"] for p in profiles if "tool-direct-healthy" in p["flags"]]
fake = [p["name"] for p in profiles if "FAKE-DISABLE" in p["flags"]]
active = [p["name"] for p in profiles if "active" in p["flags"]]
dormant = [p["name"] for p in profiles if "dormant" in p["flags"]]
phantom = [p["name"] for p in profiles if "phantom-config" in p["flags"]]

# outcome stats
oc = Counter(r["status"] for r in run_outcomes)
print(f"\n{'='*90}\nDIAGNOSTICS (improvement opportunities, no deletion)\n{'='*90}")
print(f"Run outcomes (all sessions): {dict(oc)}")
print(f"Active skills (loaded recently): {len(active)} -> {active}")
print(f"Tool-direct healthy (work via tool calls, no read needed): {len(tool_healthy)} -> {tool_healthy}")
print(f"Dormant skills (used before, not in {RECENT_DAYS}d): {len(dormant)}")
print(f"Desc-may-need-tuning (injected often, never triggered read): {len(desc_tune)} -> {desc_tune}")
print(f"FAKE-DISABLE (config disable INEFFECTIVE due to name!=dir): {fake}")
print(f"Phantom config (key but no skill on disk): {len(phantom)}")
print(f"\n💡 Improvement actions:")
if desc_tune:
    print(f"  - desc-may-need-tuning: review description/trigger words for: {', '.join(desc_tune[:10])}")
if fake:
    print(f"  - FAKE-DISABLE: fix config key to match frontmatter name for: {', '.join(fake)}")
if phantom:
    print(f"  - phantom-config: remove stale config entries (no skill on disk)")
if not desc_tune and not fake and not phantom:
    print(f"  - No urgent improvements identified. Ecosystem looks healthy.")

# ---------- 8. Machine-readable report ----------
report = {
    "generated": time.strftime("%Y-%m-%dT%H:%M:%S"),
    "recent_days": RECENT_DAYS,
    "inventory": {
        "on_disk": len(disk_skills),
        "in_roster": len(roster),
        "config_entries": len(entries_cfg),
        "disabled": sorted(disabled_keys),
    },
    "tools_schema_avg_chars": (sum(tools_schema_chars)//len(tools_schema_chars)) if tools_schema_chars else None,
    "skills_prompt_avg_chars": (sum(prompt_skill_chars)//len(prompt_skill_chars)) if prompt_skill_chars else None,
    "run_outcomes": dict(oc),
    "profiles": profiles,
    "diagnostics": {
        "active": active, "dormant": dormant, "desc_may_need_tuning": desc_tune,
        "tool_direct_healthy": tool_healthy,
        "fake_disable": fake, "phantom_config": phantom,
    },
}
out = os.path.join(STATE, "workspace", "skill-health-report.json")
with open(out, "w", encoding="utf-8") as f:
    json.dump(report, f, ensure_ascii=False, indent=2)
print(f"\n📄 machine-readable report -> {out}")

# ---------- 9. Append time-series snapshot to SKILL_LOG.jsonl (feedback loop) ----------
# One compact line per run. Accumulates over time -> used for threshold calibration (step 8/H).
log_path = os.path.join(STATE, "workspace", "SKILL_LOG.jsonl")
snapshot = {
    "ts": time.strftime("%Y-%m-%dT%H:%M:%S"),
    "on_disk": len(disk_skills),
    "in_roster": len(roster),
    "disabled": len(disabled_keys),
    "run_outcomes": dict(oc),
    "counts": {
        "active": len(active),
        "dormant": len(dormant),
        "tool_direct_healthy": len(tool_healthy),
        "desc_may_need_tuning": len(desc_tune),
        "fake_disable": len(fake),
        "phantom_config": len(phantom),
    },
    "active": active,
    "desc_may_need_tuning": desc_tune,
    "fake_disable": fake,
    "phantom_config": phantom,
}
try:
    with open(log_path, "a", encoding="utf-8") as f:
        f.write(json.dumps(snapshot, ensure_ascii=False) + "\n")
    # count accumulated snapshots
    n_lines = sum(1 for _ in open(log_path, encoding="utf-8"))
    print(f"📊 appended snapshot -> {log_path}  (total {n_lines} snapshots)")
    if n_lines >= 30:
        print(f"   ✅ {n_lines} ≥ 30 snapshots: ready for threshold calibration (step 8/H)")
    else:
        print(f"   ⏳ need {30-n_lines} more snapshots before threshold calibration")
except Exception as e:
    print(f"WARN: cannot write SKILL_LOG: {e}", file=sys.stderr)
