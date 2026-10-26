#!/usr/bin/env python3
"""Fetch the News tab's RSS/Atom feeds and write them, parsed, to a JSON cache.

Local addition for modules/sidebarRight/NewsFeed.qml. Parsing used to run in the
shell's JS engine, on the UI thread, once per sidebar instance and every time the
sidebar content was rebuilt; here it runs out of process and the widget only
reads the result.

usage: fetch_news.py <cache.json> <max_age_seconds> <feed> [<feed> ...]
       each feed is "Category|https://feed.url" (or a bare URL)

Exits without fetching when the cache is newer than max_age_seconds and was
built from the same feed list (0 forces a refresh). A lock file keeps two
sidebars from fetching at once.
"""
import email.utils
import fcntl
import html
import json
import os
import re
import sys
import tempfile
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

PER_FEED = 20
# Per category, not overall: a category with many busy feeds (Mercados) must not
# crowd the others out of the cache before the widget mixes them by weight
MAX_PER_CATEGORY = 40
TIMEOUT = 12
USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) iNiR-news/1.0"

ES_WORDS = ["de", "la", "el", "que", "en", "los", "las", "por", "con", "para", "una", "del"]
EN_WORDS = ["the", "of", "and", "to", "in", "for", "on", "with", "is", "its", "as", "at"]
GENERIC_TITLES = {"portada", "inicio", "home", "news", "noticias", "rss"}


def tag(block, name):
    m = re.search(rf"<{name}(?:\s[^>]*)?>([\s\S]*?)</{name}>", block)
    if not m:
        return ""
    return re.sub(r"<!\[CDATA\[([\s\S]*?)\]\]>", r"\1", m.group(1), count=1).strip()


def decode(text):
    # unescape twice: some feeds double-encode ("&amp;#x2019;")
    return html.unescape(html.unescape(re.sub(r"<[^>]+>", "", text or ""))).replace("\xa0", " ").strip()


def image(block):
    media = re.search(r'<(?:media:content|media:thumbnail|enclosure)[^>]*url="([^"]+)"', block)
    if media and not re.search(r"\.(mp3|mp4|m4a|ogg)(\?|$)", media.group(1), re.I):
        return html.unescape(media.group(1))
    decoded = html.unescape(block)
    # Only real image files: descriptions also carry tracking pixels
    for src in re.findall(r"""<img[^>]*src=["']([^"']+)["']""", decoded):
        if re.search(r"\.(jpe?g|png|webp|avif|gif)(\?|$)", src, re.I):
            return src
    return ""


def timestamp(date):
    if not date:
        return 0
    try:
        return int(email.utils.parsedate_to_datetime(date).timestamp())
    except (TypeError, ValueError):
        pass
    try:
        return int(datetime.fromisoformat(date.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def language(declared, titles):
    """The channel's <language> when it has one, otherwise guessed from headlines."""
    code = (declared or "").strip()[:2].lower()
    if code in ("es", "en"):
        return code
    text = " " + " ".join(titles).lower() + " "
    es = sum(text.count(f" {w} ") for w in ES_WORDS) + len(re.findall(r"[ñáéíóú¿¡]", text))
    en = sum(text.count(f" {w} ") for w in EN_WORDS)
    return "es" if es > en else "en"


def parse(xml, category):
    head_match = re.search(r"<(channel|feed)[^>]*>([\s\S]*?)<(item|entry)[\s>]", xml)
    head = head_match.group(2) if head_match else ""
    # "Portada // expansion", "Xataka - Tecnología…": keep the outlet's name.
    # The widget prefers its own per-domain names; this is the fallback.
    parts = [p for p in re.split(r"\s*(?://|\s[-|:–]\s)\s*", decode(tag(head, "title"))) if p]
    named = next((p for p in parts if p.lower() not in GENERIC_TITLES), parts[0] if parts else "")
    source = named[:1].upper() + named[1:]

    items = []
    for m in re.finditer(r"<(item|entry)[\s>]([\s\S]*?)</(item|entry)>", xml):
        if len(items) >= PER_FEED:
            break
        block = m.group(2)
        title = decode(tag(block, "title"))
        link = tag(block, "link")
        if not link:
            href = re.search(r'<link[^>]*href="([^"]+)"', block)
            link = href.group(1) if href else ""
        if not title or not link:
            continue
        url = html.unescape(link).strip()
        domain_match = re.match(r"https?://([^/]+)", url)
        date = tag(block, "pubDate") or tag(block, "updated") or tag(block, "published") or tag(block, "dc:date")
        items.append({
            "title": title,
            "url": url,
            "source": source,
            "domain": domain_match.group(1) if domain_match else "",
            "image": image(block),
            "category": category,
            "timestamp": timestamp(date),
        })
    lang = language(tag(head, "language") or tag(head, "dc:language"), [i["title"] for i in items])
    for item in items:
        item["language"] = lang
    return items


def fetch(feed):
    category, url = feed
    try:
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            xml = resp.read().decode(resp.headers.get_content_charset() or "utf-8", "replace")
        return parse(xml, category), None
    except Exception as e:  # one broken feed must not empty the tab
        return [], f"{url}: {e}"


def split_feed(entry):
    sep = entry.find("|")
    if sep > 0:
        return entry[:sep].strip(), entry[sep + 1:].strip()
    return "", entry.strip()


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    cache_path, max_age = sys.argv[1], int(sys.argv[2])
    feeds = [f for f in (split_feed(e) for e in sys.argv[3:]) if f[1]]
    feed_key = [f"{c}|{u}" for c, u in feeds]

    os.makedirs(os.path.dirname(cache_path), exist_ok=True)
    with open(cache_path + ".lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            with open(cache_path) as f:
                cached = json.load(f)
            if max_age > 0 and cached.get("feeds") == feed_key and time.time() - cached.get("fetched", 0) < max_age:
                return 0
        except (OSError, ValueError):
            pass

        articles, errors = [], []
        with ThreadPoolExecutor(max_workers=8) as pool:
            for items, error in pool.map(fetch, feeds):
                articles.extend(items)
                if error:
                    errors.append(error)
        articles.sort(key=lambda a: a["timestamp"], reverse=True)
        kept, per_category = [], {}
        for article in articles:
            count = per_category.get(article["category"], 0)
            if count < MAX_PER_CATEGORY:
                per_category[article["category"]] = count + 1
                kept.append(article)

        data = {"fetched": int(time.time()), "feeds": feed_key, "errors": errors, "articles": kept}
        # Atomic replace so the widget's file watcher never reads half a file
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(cache_path), suffix=".tmp")
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp, cache_path)
    for error in errors:
        print(error, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
