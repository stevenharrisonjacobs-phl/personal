#!/usr/bin/env python3
"""Match Steven's Spotify artists to upcoming Philadelphia-area concerts.

Pulls the taste graph from scripts/spotify.py (Spotify Web API), then gathers
upcoming Philly-area shows from:
  - Ticketmaster Discovery API (broad, structured; big + many mid venues)
  - Venue JSON-LD scrapers: Underground Arts, Ardmore Music Hall, MilkBoy
  - Johnny Brenda's (rhp_events HTML parser)
and reports the intersection, date-sorted, with ticket links.

Usage:
  scripts/shows.py                 all upcoming matches (pretty)
  scripts/shows.py --json          machine-readable JSON
  scripts/shows.py --new           only matches not seen on a prior run
                                   (updates .context/shows_seen.json)
  scripts/shows.py --radius 60     override Ticketmaster search radius (miles)
  scripts/shows.py --horizon 180   only shows within N days (default 365)

Requires .env: SPOTIFY_* (authorized via `spotify.py auth`) + TICKETMASTER_API_KEY.
"""
import datetime as dt
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "scripts"))
import spotify  # noqa: E402  (reuse OAuth + API helpers)

SEEN_PATH = os.path.join(REPO, ".context", "shows_seen.json")
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0 Safari/537.36")
PHILLY_LAT, PHILLY_LON = 39.9526, -75.1652
TODAY = dt.date.today()

# ---------------------------------------------------------------- name matching

def _strip_accents(s):
    return "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))


def norm(s):
    """Aggressive normalization for exact comparison."""
    s = _strip_accents(s.lower().strip())
    s = s.replace("&", "and")
    s = re.sub(r"^the\s+", "", s)
    s = re.sub(r"[^a-z0-9]", "", s)
    return s


# separators that divide a bill into individual acts
_SPLIT = re.compile(
    r"\bwith\b|\bw/\b|•|\||,|&|\+|\bfeat\.?\b|\bfeaturing\b|\bpresents?\b|"
    r"\bwelcomes?\b|:| x |/|~|–|—",
    re.I,
)


def taste_matches(title, taste):
    """Return set of taste-graph artist display names appearing in `title`.

    `taste` maps normalized-name -> display-name. Three passes, in order of
    confidence: whole-title exact, per-segment exact, and word-boundary
    substring (only for names long/multi-word enough to be unambiguous).
    """
    hits = set()
    if not title:
        return hits
    if norm(title) in taste:
        hits.add(taste[norm(title)])
    for seg in _SPLIT.split(title):
        n = norm(seg)
        if n and n in taste:
            hits.add(taste[n])
    for n, disp in taste.items():
        if len(disp) >= 5 or " " in disp:
            pat = r"\b" + re.escape(_strip_accents(disp)) + r"\b"
            if re.search(pat, _strip_accents(title), re.I):
                hits.add(disp)
    return hits


# ---------------------------------------------------------------- taste graph

def taste_graph():
    """{normalized_name: display_name} across top artists (3 ranges) + follows."""
    token = spotify._access_token()
    names = set()
    for rng in ("short_term", "medium_term", "long_term"):
        for a in spotify._get(f"/me/top/artists?time_range={rng}&limit=50", token)["items"]:
            names.add(a["name"])
    for a in spotify._get("/me/following?type=artist&limit=50", token)["artists"]["items"]:
        names.add(a["name"])
    return {norm(n): n for n in names}


# ---------------------------------------------------------------- http helper

def _fetch(url, timeout=30, retries=2):
    """GET with a browser UA; retry once or twice on rate-limit/transient 5xx
    with a short backoff (some aggregators, e.g. JamBase, throttle)."""
    import time
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "text/html,application/json"})
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read().decode("utf-8", "ignore")
        except urllib.error.HTTPError as e:
            if e.code in (429, 500, 502, 503) and attempt < retries:
                time.sleep(3 * (attempt + 1))
                continue
            raise


def _local_date(start):
    """Venue JSON-LD stores show times in UTC (tixr); convert to the Eastern
    calendar date so it matches Ticketmaster's localDate and dedups cleanly."""
    s = start.strip()
    if "T" not in s:
        return s[:10]
    try:
        d = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return s[:10]
    if d.tzinfo is None:
        return s[:10]
    return d.astimezone(ZoneInfo("America/New_York")).date().isoformat()


def _in_horizon(iso_date, horizon_days):
    try:
        d = dt.date.fromisoformat(iso_date[:10])
    except ValueError:
        return True  # keep undated rather than drop
    return TODAY <= d <= TODAY + dt.timedelta(days=horizon_days)


# ---------------------------------------------------------------- ticketmaster

def _geohash(lat, lon, prec=7):
    base32 = "0123456789bcdefghjkmnpqrstuvwxyz"
    lat_r, lon_r = [-90.0, 90.0], [-180.0, 180.0]
    gh, bits, bit, even = [], 0, 0, True
    while len(gh) < prec:
        if even:
            mid = sum(lon_r) / 2
            if lon > mid: bit = bit * 2 + 1; lon_r[0] = mid
            else: bit = bit * 2; lon_r[1] = mid
        else:
            mid = sum(lat_r) / 2
            if lat > mid: bit = bit * 2 + 1; lat_r[0] = mid
            else: bit = bit * 2; lat_r[1] = mid
        even = not even
        bits += 1
        if bits == 5:
            gh.append(base32[bit]); bits, bit = 0, 0
    return "".join(gh)


def ticketmaster_events(radius=40):
    spotify._load_env()
    key = os.environ.get("TICKETMASTER_API_KEY")
    if not key:
        print("  ! TICKETMASTER_API_KEY missing — skipping Ticketmaster", file=sys.stderr)
        return []
    gh = _geohash(PHILLY_LAT, PHILLY_LON, 7)
    out, page, total_pages = [], 0, 1
    while page < total_pages and page < 12:
        params = urllib.parse.urlencode({
            "apikey": key, "classificationName": "Music", "geoPoint": gh,
            "radius": str(radius), "unit": "miles", "size": "199",
            "page": str(page), "sort": "date,asc",
        })
        url = f"https://app.ticketmaster.com/discovery/v2/events.json?{params}"
        try:
            data = json.loads(_fetch(url))
        except urllib.error.HTTPError as e:
            print(f"  ! Ticketmaster HTTP {e.code} — stopping", file=sys.stderr)
            break
        total_pages = data.get("page", {}).get("totalPages", 1)
        for ev in data.get("_embedded", {}).get("events", []):
            venue = (ev.get("_embedded", {}).get("venues") or [{}])[0]
            date = ev.get("dates", {}).get("start", {}).get("localDate", "")
            for at in ev.get("_embedded", {}).get("attractions", []):
                out.append({
                    "act": at.get("name", ""), "date": date,
                    "venue": venue.get("name", "?"),
                    "city": (venue.get("city") or {}).get("name", "?"),
                    "url": ev.get("url", ""), "source": "ticketmaster",
                })
        page += 1
    return out


# ---------------------------------------------------------------- venue scrapers

def _jsonld_events(html):
    """Yield (name, startDate, url) from all JSON-LD Event objects in a page."""
    for block in re.findall(r'application/ld\+json"[^>]*>(.*?)</script>', html, re.S):
        try:
            data = json.loads(block)
        except json.JSONDecodeError:
            continue
        stack = data if isinstance(data, list) else [data]
        for it in stack:
            if not isinstance(it, dict):
                continue
            graph = it.get("@graph")
            if isinstance(graph, list):
                stack.extend(graph)
            if "startDate" in it and it.get("name"):
                url = it.get("url", "")
                offers = it.get("offers")
                if isinstance(offers, dict):
                    url = offers.get("url", url)
                elif isinstance(offers, list) and offers:
                    url = offers[0].get("url", url)
                yield str(it["name"]), str(it["startDate"]), url


def scrape_jsonld_venue(name, url):
    try:
        html = _fetch(url)
    except Exception as e:  # noqa: BLE001
        print(f"  ! {name} fetch failed: {e}", file=sys.stderr)
        return []
    out = []
    for act, start, link in _jsonld_events(html):
        out.append({"act": act, "date": _local_date(start), "venue": name,
                    "city": "Philadelphia area", "url": link or url, "source": name})
    return out


_VENUE_NAMES = {
    "johnny-brendas": "Johnny Brenda's", "philamoca": "PhilaMOCA",
    "the-first-unitarian-church": "First Unitarian Church",
    "first-unitarian-church": "First Unitarian Church",
    "kung-fu-necktie": "Kung Fu Necktie", "ukie-club": "Ukie Club",
    "underground-arts": "Underground Arts",
}


def _venue_from_url(url, fallback):
    """rhp event URLs are /event/<show>/<venue>/<city>/ — pull the real room
    (R5 books First Unitarian, PhilaMOCA, Ukie Club, ... under one feed)."""
    m = re.search(r"/event/[^/]+/([^/]+)/", url)
    if not m:
        return fallback
    slug = m.group(1)
    return _VENUE_NAMES.get(slug, slug.replace("-", " ").title())


def scrape_rhp_rss(source, feed_url, city="Philadelphia"):
    """Roster from an rhp_events (Rock House) venue's RSS feed (/events/feed/).

    Shared by Johnny Brenda's, First Unitarian (R5), Kung Fu Necktie. The RSS
    lists the FULL upcoming roster (the HTML page only renders the nearest ~25),
    but its <pubDate> is a publish timestamp, not the show date — so events come
    back with date="" and the real date is fetched per-match by _rhp_event_date.
    """
    try:
        xml = _fetch(feed_url)
    except Exception as e:  # noqa: BLE001
        print(f"  ! {name} fetch failed: {e}", file=sys.stderr)
        return []
    out = []
    for item in re.findall(r"<item>(.*?)</item>", xml, re.S):
        m_title = re.search(r"<title>(.*?)</title>", item, re.S)
        m_link = re.search(r"<link>(.*?)</link>", item, re.S)
        if not m_title:
            continue
        link = m_link.group(1).strip() if m_link else feed_url
        out.append({"act": _html_unescape(m_title.group(1).strip()), "date": "",
                    "venue": _venue_from_url(link, source), "city": city,
                    "url": link, "source": source})
    return out


def _rhp_event_date(url):
    """Show date for an rhp event page, from its `article:expiration_time` meta
    (set to end of show day; UTC → Eastern gives the date). Verified against the
    plugin's own list-view dates. Returns '' if unavailable."""
    try:
        page = _fetch(url)
    except Exception:  # noqa: BLE001
        return ""
    m = re.search(r"<meta[^>]*article:expiration_time[^>]*>", page)
    if not m:
        return ""
    c = re.search(r'content="([^"]+)"', m.group(0))
    return _local_date(c.group(1)) if c else ""


def _html_unescape(s):
    import html as _h
    return _h.unescape(s)


def _parse_us_date(s):
    """'Wed, Jul 22' -> ISO, inferring the year (roll to next year if past)."""
    m = re.search(r"([A-Za-z]{3})\s+(\d{1,2})", s)
    if not m:
        return ""
    months = {mo: i for i, mo in enumerate(
        ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1)}
    mon = months.get(m.group(1).title())
    if not mon:
        return ""
    day = int(m.group(2))
    year = TODAY.year
    try:
        d = dt.date(year, mon, day)
        if d < TODAY - dt.timedelta(days=1):
            d = dt.date(year + 1, mon, day)
        return d.isoformat()
    except ValueError:
        return ""


def scrape_jambase(name, url):
    """Scrape a JamBase venue page (JSON-LD). Used for World Cafe Live, whose
    own site is TLS-fingerprint-blocked to non-browsers and which Ticketmaster
    barely carries. JamBase mirrors the calendar on a reachable domain; event
    names are 'Artist - City - Venue - Date', so the act is the first segment.
    Dates are local (no timezone conversion). Capped at ~10 upcoming per page."""
    try:
        html = _fetch(url)
    except Exception as e:  # noqa: BLE001
        print(f"  ! {name} (JamBase) fetch failed: {e}", file=sys.stderr)
        return []
    out = []
    for act, start, link in _jsonld_events(html):
        artist = act.split(" - ")[0].strip()
        if not artist:
            continue
        out.append({"act": artist, "date": start[:10], "venue": name,
                    "city": "Philadelphia", "url": link or url, "source": name})
    return out


VENUE_SCRAPERS = [
    # tixr JSON-LD venues
    lambda: scrape_jsonld_venue("Underground Arts", "https://undergroundarts.org/"),
    lambda: scrape_jsonld_venue("Ardmore Music Hall", "https://ardmoremusichall.com/"),
    lambda: scrape_jsonld_venue("MilkBoy", "https://www.milkboyphilly.com/"),
    # rhp_events (Rock House) venues — full RSS roster; date fetched per-match
    lambda: scrape_rhp_rss("Johnny Brenda's", "https://www.johnnybrendas.com/events/feed/"),
    lambda: scrape_rhp_rss("R5 Productions", "https://r5productions.com/events/feed/"),
    lambda: scrape_rhp_rss("Kung Fu Necktie", "https://www.kungfunecktie.com/events/feed/"),
    # World Cafe Live via JamBase (own site is TLS-fingerprint-blocked)
    lambda: scrape_jambase("World Cafe Live", "https://www.jambase.com/venue/world-cafe-live-philadelphia"),
    lambda: scrape_jambase("World Cafe Live (Lounge)", "https://www.jambase.com/venue/the-lounge-at-world-cafe-live"),
]


# ---------------------------------------------------------------- orchestration

def gather(radius, horizon):
    events = ticketmaster_events(radius)
    for scraper in VENUE_SCRAPERS:
        events.extend(scraper())
    return [e for e in events if _in_horizon(e["date"], horizon)]


def match(events, taste, horizon=365):
    """Return list of match dicts: one per (artist, date, venue).

    RSS-sourced events arrive dateless; their show date is fetched here (only for
    the handful that actually match), then out-of-horizon rows are dropped.
    """
    raw = []
    for e in events:
        if e["source"] == "ticketmaster":
            acts = {taste[norm(e["act"])]} if norm(e["act"]) in taste else set()
        else:
            acts = taste_matches(e["act"], taste)
        for artist in acts:
            raw.append({"artist": artist, "date": e["date"], "venue": e["venue"],
                        "city": e["city"], "url": e["url"], "source": e["source"],
                        "billing": e["act"]})

    seen, matches = set(), []
    for m in raw:
        if not m["date"] and m["url"].startswith("http"):
            m["date"] = _rhp_event_date(m["url"])  # per-match date lookup
        if m["date"] and not _in_horizon(m["date"], horizon):
            continue
        key = (norm(m["artist"]), m["date"], norm(m["venue"]))
        if key in seen:
            continue
        seen.add(key)
        matches.append(m)
    matches.sort(key=lambda m: (m["date"] or "9999", m["artist"].lower()))
    return matches


def _event_id(m):
    return f"{norm(m['artist'])}|{m['date']}|{norm(m['venue'])}"


def load_seen():
    if os.path.exists(SEEN_PATH):
        return set(json.load(open(SEEN_PATH)))
    return set()


def save_seen(ids):
    os.makedirs(os.path.dirname(SEEN_PATH), exist_ok=True)
    json.dump(sorted(ids), open(SEEN_PATH, "w"), indent=0)


def main():
    args = sys.argv[1:]
    as_json = "--json" in args
    only_new = "--new" in args
    radius = int(_argval(args, "--radius", 40))
    horizon = int(_argval(args, "--horizon", 365))

    taste = taste_graph()
    events = gather(radius, horizon)
    matches = match(events, taste, horizon)

    if only_new:
        seen = load_seen()
        fresh = [m for m in matches if _event_id(m) not in seen]
        save_seen(seen | {_event_id(m) for m in matches})
        matches = fresh

    if as_json:
        print(json.dumps(matches, indent=2))
        return

    if not matches:
        print("No upcoming Philly-area shows matched your Spotify artists"
              + (" (nothing new since last run)." if only_new else "."))
        return
    label = "NEW matches" if only_new else "matches"
    print(f"🎟  {len(matches)} {label} — your Spotify artists playing the Philly area\n")
    for m in matches:
        date = m["date"] or "date TBA"
        print(f"  {date}  {m['artist']}")
        bill = m["billing"]
        extra = f'  ·  on bill: "{bill}"' if norm(bill) != norm(m["artist"]) else ""
        print(f"            {m['venue']}, {m['city']}  ({m['source']}){extra}")
        if m["url"]:
            print(f"            {m['url']}")
    print()


def _argval(args, flag, default):
    if flag in args:
        i = args.index(flag)
        if i + 1 < len(args):
            return args[i + 1]
    return default


if __name__ == "__main__":
    main()
