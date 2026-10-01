#!/usr/bin/env python3
"""Local, per-business store for Venture System.

Everything lives on this Mac, under the user's own Application Support folder.
Nothing is uploaded anywhere. One folder per business, so a business can be
moved, backed up, or dropped into iCloud/Dropbox by moving the folder - the
same convention Live Project Packs uses for packs.

    ~/Library/Application Support/VentureSystem/
      config.json                  which businesses exist, which is selected
      Businesses/<Name>/
        business.json              identity + the six intake answers
        decisions.json             structure / sales-tax calls, with reasons
        progress.json              which steps are settled, and when
        records.json               real values: name, BN, registration number
        log.json                   the system log
        Documents/<step>/          evidence files for that step

Usage
    venture-store.py init "Northwind Landscaping" --province ON --work physical \
        --people solo --revenue under30 --customers consumers --hiring no
    venture-store.py list
    venture-store.py show "Northwind Landscaping"
    venture-store.py decide "Northwind Landscaping" structure sole --why "low exposure"
    venture-store.py complete "Northwind Landscaping" bn
    venture-store.py attach "Northwind Landscaping" bn ~/Downloads/bn-confirmation.pdf
    venture-store.py export "Northwind Landscaping"        # JSON for the prototype
    venture-store.py import "Northwind Landscaping" state.json

Security note: these are plain JSON files. The store directory is created 0700
so other accounts on this Mac cannot read it, and FileVault protects it at rest.
That is privacy by locality, not encryption. Never put CRA or bank credentials
in here - those belong in Keychain.
"""

import argparse
import datetime as dt
import json
import os
import re
import shutil
import sys

ROOT = os.path.expanduser("~/Library/Application Support/VentureSystem")
BIZ = os.path.join(ROOT, "Businesses")
CONFIG = os.path.join(ROOT, "config.json")
PROFILE_KEYS = ["province", "work", "people", "revenue", "customers", "hiring"]


def now():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def safe_name(name):
    cleaned = re.sub(r"[/\x00]", "-", (name or "").strip())
    return cleaned[:120] or "Business"


def write_json(path, data):
    """Write atomically so a crash mid-write can't truncate the file."""
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    os.replace(tmp, path)
    os.chmod(path, 0o600)


def read_json(path, default=None):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {} if default is None else default


def ensure_root():
    os.makedirs(BIZ, exist_ok=True)
    for d in (ROOT, BIZ):
        try:
            os.chmod(d, 0o700)   # this user only
        except OSError:
            pass


def biz_dir(name):
    return os.path.join(BIZ, safe_name(name))


def require(name):
    d = biz_dir(name)
    if not os.path.isdir(d):
        sys.exit(f"No business named {safe_name(name)!r}. Run: venture-store.py list")
    return d


def register(name):
    cfg = read_json(CONFIG, {})
    names = cfg.get("businesses", [])
    if safe_name(name) not in names:
        names.append(safe_name(name))
    cfg.update({"version": 1, "businesses": names, "selected": names.index(safe_name(name))})
    write_json(CONFIG, cfg)


def log(name, kind, text):
    p = os.path.join(biz_dir(name), "log.json")
    entries = read_json(p, {}).get("entries", [])
    entries.append({"at": now(), "kind": kind, "text": text})
    write_json(p, {"entries": entries})


# ---------------------------------------------------------------- commands
def cmd_init(a):
    ensure_root()
    d = biz_dir(a.name)
    if os.path.isdir(d) and not a.force:
        sys.exit(f"{safe_name(a.name)!r} already exists. Use --force to overwrite its profile.")
    os.makedirs(os.path.join(d, "Documents"), exist_ok=True)
    os.chmod(d, 0o700)
    profile = {k: getattr(a, k) for k in PROFILE_KEYS if getattr(a, k)}
    write_json(os.path.join(d, "business.json"),
               {"name": safe_name(a.name), "created": now(), "profile": profile})
    write_json(os.path.join(d, "decisions.json"), {})
    write_json(os.path.join(d, "progress.json"), {"settled": []})
    write_json(os.path.join(d, "log.json"), {"entries": []})
    register(a.name)
    log(a.name, "set", "Business created on this Mac.")
    print(f"Created {d}")
    missing = [k for k in PROFILE_KEYS if k not in profile]
    if missing:
        print("Profile incomplete — still needed: " + ", ".join(missing))


def cmd_list(a):
    ensure_root()
    names = read_json(CONFIG, {}).get("businesses", [])
    if not names:
        print("No businesses yet. Run: venture-store.py init \"Name\"")
        return
    for n in names:
        d = biz_dir(n)
        prog = read_json(os.path.join(d, "progress.json"), {}).get("settled", [])
        docs = sum(len(f) for _, _, f in os.walk(os.path.join(d, "Documents")))
        print(f"  {n:<34} {len(prog)} settled · {docs} document(s)")


def cmd_show(a):
    d = require(a.name)
    biz = read_json(os.path.join(d, "business.json"))
    dec = read_json(os.path.join(d, "decisions.json"))
    prog = read_json(os.path.join(d, "progress.json"), {}).get("settled", [])
    entries = read_json(os.path.join(d, "log.json"), {}).get("entries", [])
    print(f"{biz.get('name')}   created {biz.get('created','?')[:10]}")
    print(f"  folder    {d}")
    print(f"  profile   " + (", ".join(f"{k}={v}" for k, v in biz.get("profile", {}).items()) or "(empty)"))
    print(f"  decisions " + (", ".join(f"{k}={v.get('choice')}" for k, v in dec.items()) or "(none)"))
    print(f"  settled   " + (", ".join(s["step"] for s in prog) or "(none)"))
    if biz.get("does"):
        print(f"  does      {biz['does']}")
    for k, v in read_json(os.path.join(d, "records.json")).items():
        print(f"  {k:<9} {v}")
    docroot = os.path.join(d, "Documents")
    for step in sorted(os.listdir(docroot)) if os.path.isdir(docroot) else []:
        files = os.listdir(os.path.join(docroot, step))
        if files:
            print(f"  evidence  {step}: {', '.join(files)}")
    for e in entries[-5:]:
        print(f"  [{e['at'][11:16]}] {e['kind']:<4} {e['text']}")


def cmd_set(a):
    d = require(a.name)
    p = os.path.join(d, "business.json")
    biz = read_json(p)
    prof = biz.get("profile", {})
    changed = {k: getattr(a, k) for k in PROFILE_KEYS if getattr(a, k)}
    prof.update(changed)
    biz["profile"] = prof
    write_json(p, biz)
    log(a.name, "set", "Profile updated: " + ", ".join(f"{k}={v}" for k, v in changed.items()))
    print("Profile: " + ", ".join(f"{k}={v}" for k, v in prof.items()))


def cmd_decide(a):
    d = require(a.name)
    p = os.path.join(d, "decisions.json")
    dec = read_json(p)
    dec[a.topic] = {"choice": a.choice, "why": a.why or "", "at": now()}
    write_json(p, dec)
    _settle(a.name, a.topic)
    log(a.name, "done", f"Decision — {a.topic}: {a.choice}" + (f" ({a.why})" if a.why else ""))
    print(f"{a.topic} = {a.choice}")


def _settle(name, step):
    p = os.path.join(biz_dir(name), "progress.json")
    prog = read_json(p, {"settled": []})
    if not any(s["step"] == step for s in prog["settled"]):
        prog["settled"].append({"step": step, "at": now()})
        write_json(p, prog)


def cmd_complete(a):
    require(a.name)
    _settle(a.name, a.step)
    log(a.name, "done", f"{a.step} — settled.")
    print(f"{a.step} settled")


def cmd_attach(a):
    d = require(a.name)
    if not os.path.isfile(a.file):
        sys.exit(f"No such file: {a.file}")
    dest_dir = os.path.join(d, "Documents", a.step)
    os.makedirs(dest_dir, exist_ok=True)
    os.chmod(dest_dir, 0o700)
    dest = os.path.join(dest_dir, os.path.basename(a.file))
    stem, ext = os.path.splitext(dest)
    n = 2
    while os.path.exists(dest):
        dest = f"{stem}-{n}{ext}"
        n += 1
    shutil.copy2(a.file, dest)
    os.chmod(dest, 0o600)
    log(a.name, "done", f"Evidence attached to {a.step}: {os.path.basename(dest)}")
    print(f"Attached -> {dest}")


def cmd_record(a):
    d = require(a.name)
    p = os.path.join(d, "records.json")
    rec = read_json(p)
    rec[a.key] = a.value
    write_json(p, rec)
    log(a.name, "done", f"Recorded {a.key}: {a.value}")
    print(f"{a.key} = {a.value}")


def cmd_export(a):
    d = require(a.name)
    biz = read_json(os.path.join(d, "business.json"))
    dec = read_json(os.path.join(d, "decisions.json"))
    prog = read_json(os.path.join(d, "progress.json"), {}).get("settled", [])
    rec = read_json(os.path.join(d, "records.json"))
    out = {
        "profile": dict(biz.get("profile", {}), name=biz.get("name", ""),
                        does=biz.get("does", ""), _started=True),
        "decisions": {k: v.get("choice") for k, v in dec.items()},
        "records": rec,
        "done": [s["step"] for s in prog],
        "feed": read_json(os.path.join(d, "log.json"), {}).get("entries", [])[-8:],
    }
    print(json.dumps(out, indent=2, ensure_ascii=False))


def cmd_import(a):
    d = require(a.name)
    raw = sys.stdin.read() if a.file == "-" else open(a.file, encoding="utf-8").read()
    try:
        state = json.loads(raw)
    except ValueError as exc:
        sys.exit(f"That isn't valid JSON: {exc}")

    incoming = state.get("profile") or {}
    prof = {k: v for k, v in incoming.items() if k in PROFILE_KEYS}
    p = os.path.join(d, "business.json")
    biz = read_json(p)
    biz["profile"] = dict(biz.get("profile", {}), **prof)
    if incoming.get("does"):
        biz["does"] = incoming["does"]
    write_json(p, biz)

    if state.get("records"):
        rp = os.path.join(d, "records.json")
        write_json(rp, dict(read_json(rp), **state["records"]))

    dec = read_json(os.path.join(d, "decisions.json"))
    for topic, choice in (state.get("decisions") or {}).items():
        dec.setdefault(topic, {"why": "imported from prototype", "at": now()})
        dec[topic]["choice"] = choice
    write_json(os.path.join(d, "decisions.json"), dec)

    prog = read_json(os.path.join(d, "progress.json"), {"settled": []})
    known = {s["step"] for s in prog["settled"]}
    for step in state.get("done") or []:
        if step not in known:
            prog["settled"].append({"step": step, "at": now()})
    write_json(os.path.join(d, "progress.json"), prog)

    log(a.name, "set", "Imported state from the prototype.")
    print(f"Imported into {d}")
    cmd_show(a)


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def profile_args(p):
        p.add_argument("--province", choices=["ON", "BC", "AB", "QC", "other"])
        p.add_argument("--work", choices=["service", "physical", "retail", "digital"])
        p.add_argument("--people", choices=["solo", "partners"])
        p.add_argument("--revenue", choices=["under30", "over30", "unsure"])
        p.add_argument("--customers", choices=["consumers", "businesses", "both"])
        p.add_argument("--hiring", choices=["yes", "no"])

    i = sub.add_parser("init", help="create a business folder")
    i.add_argument("name"); i.add_argument("--force", action="store_true"); profile_args(i)
    i.set_defaults(func=cmd_init)

    l = sub.add_parser("list", help="list businesses on this Mac"); l.set_defaults(func=cmd_list)

    s = sub.add_parser("show", help="show one business"); s.add_argument("name")
    s.set_defaults(func=cmd_show)

    st = sub.add_parser("set", help="update the intake profile"); st.add_argument("name")
    profile_args(st); st.set_defaults(func=cmd_set)

    de = sub.add_parser("decide", help="record a decision")
    de.add_argument("name"); de.add_argument("topic"); de.add_argument("choice")
    de.add_argument("--why"); de.set_defaults(func=cmd_decide)

    c = sub.add_parser("complete", help="mark a step settled")
    c.add_argument("name"); c.add_argument("step"); c.set_defaults(func=cmd_complete)

    at = sub.add_parser("attach", help="copy an evidence document in")
    at.add_argument("name"); at.add_argument("step"); at.add_argument("file")
    at.set_defaults(func=cmd_attach)

    r = sub.add_parser("record", help="store a real value (business number, etc.)")
    r.add_argument("name"); r.add_argument("key"); r.add_argument("value")
    r.set_defaults(func=cmd_record)

    e = sub.add_parser("export", help="print JSON for the prototype")
    e.add_argument("name"); e.set_defaults(func=cmd_export)

    im = sub.add_parser("import", help="load JSON exported from the prototype")
    im.add_argument("name"); im.add_argument("file", help="path, or - for stdin")
    im.set_defaults(func=cmd_import)

    a = ap.parse_args()
    ensure_root()
    a.func(a)


if __name__ == "__main__":
    main()
