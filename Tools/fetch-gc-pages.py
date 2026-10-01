#!/usr/bin/env python3
"""Save Government of Canada pages as clean Markdown, for use as source material.

    ./fetch-gc-pages.py --links https://www.canada.ca/en/services/business.html
    ./fetch-gc-pages.py URL [URL ...]
    ./fetch-gc-pages.py --from-file urls.txt -o corpus/

--links prints the child pages of a hub so you can pick the ones you want, one by
one, into a url list. Then fetch that list.

Stdlib only - no pip install. Obeys robots.txt, waits between requests, and never
downloads images (which also keeps the protected Canada wordmark out of your files).

canada.ca terms: non-commercial reproduction is allowed with attribution and a
note that it is not an official version - the front matter written into each file
records what you need. Commercial redistribution needs written permission.
Official symbols (wordmark, Arms, flag) may not be reproduced at all.
"""

import argparse
import datetime as dt
import html
import os
import re
import sys
import time
import urllib.parse
import subprocess
import urllib.request
import urllib.robotparser
from html.parser import HTMLParser

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

# Chrome and page furniture we never want in the prose.
SKIP_TAGS = {"script", "style", "noscript", "nav", "header", "footer", "aside",
             "form", "button", "svg", "img", "picture", "iframe", "select"}
# Void elements never produce an end tag, so they must never move the skip depth -
# otherwise the first <img> or <meta> pushes it up and it never comes back down.
VOID_TAGS = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link",
             "meta", "param", "source", "track", "wbr"}
SKIP_CLASS_HINTS = ("experiencefragment", "breadcrumb", "pagedetails",
                    "report-problem", "wb-inv",
                    "wb-share", "gc-subway__nav", "pagedetails", "wb-disable",
                    "gc-followus", "gc-main-footer", "mwsgeneric-base-html")


class Extractor(HTMLParser):
    """Turns canada.ca's semantic markup into Markdown."""

    def __init__(self, base_url):
        super().__init__(convert_charrefs=True)
        self.base = base_url
        self.out = []
        self.in_main = False
        self.main_depth = 0
        self.skip_depth = 0
        self.tag_stack = []
        self.list_stack = []
        self.link = None
        self.link_text = []
        self.row, self.cell, self.table = None, None, None

    # -- helpers ---------------------------------------------------------
    def emit(self, text):
        if self.link is not None:
            self.link_text.append(text)
        elif self.cell is not None:
            self.cell.append(text)
        else:
            self.out.append(text)

    def block(self, text=""):
        self.out.append("\n" + text)

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        classes = a.get("class", "")

        void = tag in VOID_TAGS
        if self.skip_depth:
            if not void:
                self.skip_depth += 1
            return
        if tag in SKIP_TAGS or any(h in classes for h in SKIP_CLASS_HINTS):
            if not void:
                self.skip_depth = 1
            return

        if tag == "main":
            self.in_main = True
            self.main_depth = 1
            return
        if not self.in_main:
            return
        self.main_depth += 1

        if re.fullmatch(r"h[1-6]", tag):
            self.block("\n" + "#" * int(tag[1]) + " ")
        elif tag == "p":
            self.block("\n")
        elif tag in ("ul", "ol"):
            self.list_stack.append([tag, 0])
            self.block("")
        elif tag == "li" and self.list_stack:
            kind, n = self.list_stack[-1]
            n += 1
            self.list_stack[-1][1] = n
            indent = "  " * (len(self.list_stack) - 1)
            self.block(indent + ("- " if kind == "ul" else f"{n}. "))
        elif tag == "a":
            self.link = urllib.parse.urljoin(self.base, a.get("href", ""))
            self.link_text = []
        elif tag in ("strong", "b"):
            self.emit("**")
        elif tag in ("em", "i"):
            self.emit("*")
        elif tag == "br":
            self.emit("  \n")
        elif tag == "table":
            self.table = []
        elif tag == "tr" and self.table is not None:
            self.row = []
        elif tag in ("td", "th") and self.row is not None:
            self.cell = []
        elif tag == "blockquote":
            self.block("\n> ")

    def handle_startendtag(self, tag, attrs):
        # Self-closing form: start only, never a synthetic end tag.
        self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag):
        if self.skip_depth:
            self.skip_depth -= 1
            return
        if tag == "main":
            self.in_main = False
            return
        if not self.in_main:
            return
        self.main_depth -= 1

        if tag == "a" and self.link is not None:
            text = re.sub(r"\s+", " ", "".join(self.link_text)).strip()
            href, self.link, self.link_text = self.link, None, []
            if text:
                self.emit(f"[{text}]({href})" if href.startswith("http") else text)
        elif tag in ("strong", "b"):
            self.emit("**")
        elif tag in ("em", "i"):
            self.emit("*")
        elif tag in ("ul", "ol") and self.list_stack:
            self.list_stack.pop()
            self.block("")
        elif tag in ("p", "blockquote"):
            self.block("")
        elif tag in ("td", "th") and self.cell is not None:
            self.row.append(re.sub(r"\s+", " ", "".join(self.cell)).strip())
            self.cell = None
        elif tag == "tr" and self.row is not None:
            self.table.append(self.row)
            self.row = None
        elif tag == "table" and self.table is not None:
            self.write_table()
            self.table = None

    def write_table(self):
        rows = [r for r in self.table if any(c for c in r)]
        if not rows:
            return
        width = max(len(r) for r in rows)
        rows = [r + [""] * (width - len(r)) for r in rows]
        self.block("")
        self.out.append("\n| " + " | ".join(rows[0]) + " |")
        self.out.append("\n| " + " | ".join(["---"] * width) + " |")
        for r in rows[1:]:
            self.out.append("\n| " + " | ".join(r) + " |")
        self.out.append("\n")

    def handle_data(self, data):
        if self.skip_depth or not self.in_main:
            return
        text = re.sub(r"[ \t\r\n]+", " ", data)
        if text.strip() or (self.out and not self.out[-1].endswith(" ")):
            self.emit(text)

    def markdown(self):
        text = "".join(self.out)
        text = re.sub(r"[ \t]+", " ", text)
        text = re.sub(r" *\n *", "\n", text)
        text = re.sub(r"\n{3,}", "\n\n", text)
        return text.strip()


def fetch(url):
    """Fetch via curl. urllib hangs on canada.ca's CDN; curl handles it fine and
    ships with macOS, so this is the pragmatic backend rather than the pure one."""
    proc = subprocess.run(
        # --http1.1: canada.ca's CDN intermittently kills HTTP/2 streams (curl 92).
        # No --compressed: canada.ca's CDN accepts the request then never sends a
        # body, hanging until timeout. Plain identity encoding returns instantly.
        ["curl", "-sSL", "--http1.1", "--retry", "2",
         "--retry-delay", "1", "--max-time", "30", "-A", UA,
         # No Accept-Language header: canada.ca's CDN accepts the request and then
         # never sends a body when one is present. Language comes from the /en/ path.
         "-w", "\n%{url_effective}", url],
        capture_output=True, timeout=60)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.decode("utf-8", "replace").strip()
                           or f"curl exited {proc.returncode}")
    out = proc.stdout.decode("utf-8", errors="replace")
    split = out.rfind("\n")
    if split == -1:
        return out, url
    return out[:split], out[split + 1:].strip() or url


def page_title(doc):
    m = re.search(r"<title[^>]*>(.*?)</title>", doc, re.S | re.I)
    return re.sub(r"\s+", " ", html.unescape(m.group(1))).strip() if m else "Untitled"


def slug(url):
    path = urllib.parse.urlparse(url).path
    name = os.path.splitext(os.path.basename(path))[0] or "index"
    parent = os.path.basename(os.path.dirname(path))
    stem = f"{parent}-{name}" if parent and parent != name else name
    return re.sub(r"[^a-z0-9-]+", "-", stem.lower()).strip("-")[:80] or "page"


def canonical(url):
    """Collapse AEM's internal /content/canadasite/en/ paths to the public form."""
    return url.replace("/content/canadasite/en/", "/en/")


def child_links(doc, base):
    parser = Extractor(base)
    parser.feed(doc)
    seen, out = set(), []
    for m in re.finditer(r"\[([^\]]+)\]\((https://www\.canada\.ca/[^)]+)\)", parser.markdown()):
        text = re.sub(r"\s+", " ", m.group(1)).strip()
        href = canonical(m.group(2).split("#")[0])
        if not text or href in seen or href.rstrip("/") == canonical(base).rstrip("/"):
            continue
        seen.add(href)
        out.append((text, href))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("urls", nargs="*")
    ap.add_argument("-o", "--out", default="gc-corpus", help="output folder")
    ap.add_argument("--from-file", help="file with one URL per line (# comments ok)")
    ap.add_argument("--links", metavar="URL", help="list child pages instead of saving")
    ap.add_argument("--delay", type=float, default=1.0, help="seconds between requests")
    args = ap.parse_args()

    robots = urllib.robotparser.RobotFileParser()
    try:
        rules, _ = fetch("https://www.canada.ca/robots.txt")
        robots.parse(rules.splitlines())
    except Exception:
        robots = None

    if args.links:
        doc, final = fetch(args.links)
        for text, href in child_links(doc, final):
            print(f"{href}\n    # {text}")
        return 0

    urls = list(args.urls)
    if args.from_file:
        with open(args.from_file) as fh:
            urls += [ln.split("#")[0].strip() for ln in fh if ln.split("#")[0].strip()]
    if not urls:
        ap.error("give at least one URL, --from-file, or --links")

    os.makedirs(args.out, exist_ok=True)
    saved = skipped = 0
    for i, url in enumerate(urls):
        if robots and not robots.can_fetch(UA, url):
            print(f"  robots.txt disallows, skipping: {url}", file=sys.stderr)
            skipped += 1
            continue
        try:
            doc, final = fetch(url)
        except Exception as exc:
            print(f"  failed {url}: {exc}", file=sys.stderr)
            skipped += 1
            continue

        title = page_title(doc)
        parser = Extractor(final)
        parser.feed(doc)
        body = parser.markdown()
        if len(body) < 200:
            print(f"  almost no text extracted, skipping: {url}", file=sys.stderr)
            skipped += 1
            continue

        path = os.path.join(args.out, slug(final) + ".md")
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(f"---\ntitle: {title}\nsource: {final}\n"
                     f"retrieved: {dt.date.today().isoformat()}\n"
                     f"rights: Reproduced from Canada.ca for non-commercial use. "
                     f"Not an official version; not endorsed by the Government of Canada.\n---\n\n")
            fh.write(body + "\n")
        saved += 1
        print(f"  {title}\n    -> {path} ({len(body):,} chars)")
        if i < len(urls) - 1:
            time.sleep(args.delay)

    print(f"\nSaved {saved} page(s) to {args.out}/" + (f", skipped {skipped}" if skipped else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
