"""
01d_scrape_cfb_defense.py

Scrapes individual player defensive stats from Sports Reference CFB school pages
for the college seasons needed to fill the cfbfastR gap (pre-2016).

Source: https://www.sports-reference.com/cfb/schools/{slug}/{year}.html
        Table: #defense_standard

Strategy: only scrape school-year combinations we actually need — schools that
produced unmatched draft prospects in defensive positions, 2006–2016 draft classes.
Reduces page count from ~130 schools × 14 years to ~300–500 targeted requests.

Step 1 — Scrape SR schools index to build college name → slug mapping
Step 2 — Load unmatched prospects from 01c output
Step 3 — Scrape school pages for relevant (school, year) pairs
Step 4 — Output data/01d_cfb_defense_supplemental.csv

Requires: pip install cloudscraper beautifulsoup4 pandas
"""

import argparse
import cloudscraper
from bs4 import BeautifulSoup
import pandas as pd
import time
import random
import os
import re

# ============================================================================
# CLI Arguments
# ============================================================================
parser = argparse.ArgumentParser(description="Scrape SR CFB defensive stats")
parser.add_argument('--year',      type=int, help='Scrape only this college season year (e.g. 2012)')
parser.add_argument('--year-from', type=int, help='Scrape seasons >= this year')
parser.add_argument('--year-to',   type=int, help='Scrape seasons <= this year')
parser.add_argument('--max-pages', type=int, default=100, help='Max new (uncached) pages to fetch this run (default: 100)')
parser.add_argument('--resume',    action='store_true', help='Prioritize uncached pairs first (default: True when --max-pages is set)')
args = parser.parse_args()

CACHE_DIR   = "data/cfb_defense_cache"
STATS_INPUT = "data/01c_college_stats.rds"   # checked for existence only
OUTPUT      = "data/01d_cfb_defense_supplemental.csv"

# College stats CSV — R script writes this so Python can read without rpy2.
# Run this first in R: write_csv(college_stats, "data/01c_college_stats.csv")
PROSPECTS_CSV = "data/01c_prospects_unmatched.csv"

os.makedirs(CACHE_DIR, exist_ok=True)

scraper = cloudscraper.create_scraper(
    browser={'browser': 'chrome', 'platform': 'darwin', 'mobile': False}
)

# ============================================================================
# Normalize helpers — must stay in sync with 01c_load_college_stats.R
# ============================================================================

def normalize_name(name):
    name = name.lower().strip()
    name = re.sub(r'\s+(jr\.?|sr\.?|ii|iii|iv)$', '', name)
    name = re.sub(r'[^a-z ]', '', name)
    return ' '.join(name.split())

def normalize_college(college):
    college = college.lower()
    college = re.sub(r'\.', '', college)
    return ' '.join(college.split())

def safe_num(val):
    try:
        cleaned = re.sub(r'[^0-9.]', '', str(val))
        return float(cleaned) if cleaned else None
    except Exception:
        return None

def fetch_html(url, cache_file, delay=4):
    """Fetch URL with cloudscraper, caching HTML to disk."""
    if os.path.exists(cache_file):
        with open(cache_file, 'r', encoding='utf-8') as f:
            return f.read()
    try:
        resp = scraper.get(url, timeout=30)
        if resp.status_code != 200:
            print(f"  HTTP {resp.status_code}: {url}")
            return None
        html = resp.text
        with open(cache_file, 'w', encoding='utf-8') as f:
            f.write(html)
        time.sleep(delay + random.uniform(0, 3))
        return html
    except Exception as e:
        print(f"  Failed: {url} — {e}")
        return None

# ============================================================================
# Step 1 — Build college name → SR slug mapping from schools index
# ============================================================================

def build_slug_map():
    """Scrape SR CFB schools index to get name → slug mapping."""
    print("Building SR school slug map...")
    cache = os.path.join(CACHE_DIR, "schools_index.html")
    html  = fetch_html(
        "https://www.sports-reference.com/cfb/schools/",
        cache, delay=3
    )
    if html is None:
        return {}

    soup  = BeautifulSoup(html, 'html.parser')
    table = soup.find('table', {'id': 'schools'})
    if table is None:
        print("  Could not find schools table — slug map will be empty")
        return {}

    slug_map = {}
    for a in table.find_all('a', href=True):
        m = re.match(r'/cfb/schools/([^/]+)/', a['href'])
        if m:
            slug = m.group(1)
            name = normalize_college(a.get_text(strip=True))
            slug_map[name] = slug

    print(f"  {len(slug_map)} schools indexed")
    return slug_map

# ============================================================================
# Step 2 — Load unmatched prospects
#
# Requires data/01c_prospects_unmatched.csv — produce it from R before running:
#   library(tidyverse)
#   college_stats <- read_rds("data/01c_college_stats.rds")
#   college_stats |>
#     filter(model_group %in% c("lb","dl","cb","s"), is.na(def_tot),
#            season %in% 2006:2016) |>
#     select(season, pick, pfr_player_name, college, college_norm, model_group) |>
#     write_csv("data/01c_prospects_unmatched.csv")
# ============================================================================

def load_unmatched():
    if not os.path.exists(PROSPECTS_CSV):
        print(f"\nMissing {PROSPECTS_CSV}")
        print("Run this in R first:")
        print("""  library(tidyverse)
  college_stats <- read_rds("data/01c_college_stats.rds")
  college_stats |>
    filter(model_group %in% c("lb","dl","cb","s"), is.na(def_tot),
           season %in% 2006:2016) |>
    select(season, pick, pfr_player_name, college, college_norm, model_group) |>
    write_csv("data/01c_prospects_unmatched.csv")""")
        raise SystemExit(1)

    df = pd.read_csv(PROSPECTS_CSV)
    print(f"Loaded {len(df)} unmatched defensive prospects")
    return df

# ============================================================================
# Step 3 — Match college names to SR slugs (exact then fuzzy)
# ============================================================================

def match_slug(college_norm, slug_map):
    """
    Resolve college name to SR slug.
    Priority: exact index match → manual overrides → derived slug.
    Since the SR schools index may be blocked, derived slugs are the primary
    path — SR URLs are usually just the normalized name with spaces → hyphens.
    Unresolvable names return a best-guess slug; 404s are handled gracefully.
    """
    if college_norm in slug_map:
        return slug_map[college_norm]

    manual = {
        'ohio st':            'ohio-state',
        'florida st':         'florida-state',
        'michigan st':        'michigan-state',
        'penn st':            'penn-state',
        'usc':                'southern-california',
        'miami (fl)':         'miami-fl',
        'miami fl':           'miami-fl',
        'miami (oh)':         'miami-oh',
        'miami oh':           'miami-oh',
        'tcu':                'texas-christian',
        'lsu':                'lsu',
        'ucf':                'central-florida',
        'smu':                'southern-methodist',
        'unlv':               'nevada-las-vegas',
        'utep':               'texas-el-paso',
        'utsa':               'texas-san-antonio',
        'uab':                'alabama-birmingham',
        'nc state':           'north-carolina-state',
        'north carolina st':  'north-carolina-state',
        'ole miss':           'mississippi',
        'pitt':               'pittsburgh',
        'vt':                 'virginia-tech',
        'virginia tech':      'virginia-tech',
        'hawaii':             'hawaii',
        "hawai'i":            'hawaii',
        'byu':                'brigham-young',
        'brigham young':      'brigham-young',
        'fiu':                'florida-international',
        'georgia tech':       'georgia-tech',
        'texas am':           'texas-am',
        'texas a&m':          'texas-am',
        'san jose st':        'san-jose-state',
        'boise st':           'boise-state',
        'fresno st':          'fresno-state',
        'arizona st':         'arizona-state',
        'colorado st':        'colorado-state',
        'iowa st':            'iowa-state',
        'kansas st':          'kansas-state',
        'oregon st':          'oregon-state',
        'washington st':      'washington-state',
        'oklahoma st':        'oklahoma-state',
        'mississippi st':     'mississippi-state',
        'louisiana st':       'lsu',
        'southern cal':       'southern-california',
        'central florida':    'central-florida',
        'northern illinois':  'northern-illinois',
        'western michigan':   'western-michigan',
        'eastern michigan':   'eastern-michigan',
        'bowling green st':   'bowling-green',
        'bowling green':      'bowling-green',
        'kent st':            'kent-state',
        'ball st':            'ball-state',
        'illinois st':        'illinois-state',
    }

    if college_norm in manual:
        return manual[college_norm]

    # Derive slug from normalized name — works for most FBS schools
    # e.g. "north carolina" → "north-carolina", "alabama" → "alabama"
    return college_norm.replace(' ', '-')

# ============================================================================
# Step 4 — Scrape school defense page for a given year
# ============================================================================

def scrape_school_defense(slug, year):
    """Scrape #defense_standard table from a school's season page."""
    url        = f"https://www.sports-reference.com/cfb/schools/{slug}/{year}.html"
    cache_file = os.path.join(CACHE_DIR, f"{slug}_{year}.html")

    html = fetch_html(url, cache_file, delay=8)
    if html is None:
        return []

    soup  = BeautifulSoup(html, 'html.parser')
    table = soup.find('table', {'id': 'defense_standard'})

    # SR sometimes wraps table in a comment for ad-block — unwrap if needed
    if table is None:
        for comment in soup.find_all(string=lambda t: isinstance(t, type(soup)) and 'defense_standard' in str(t)):
            inner = BeautifulSoup(str(comment), 'html.parser')
            table = inner.find('table', {'id': 'defense_standard'})
            if table:
                break

    if table is None:
        return []

    # Parse header
    headers = []
    for tr in table.find('thead').find_all('tr'):
        cells = [c.get_text(strip=True) for c in tr.find_all(['th', 'td'])]
        if 'Player' in cells:
            headers = cells
            break

    if not headers:
        return []

    rows = []
    for tr in table.find('tbody').find_all('tr'):
        if tr.get('class') and 'thead' in tr.get('class'):
            continue
        cells = tr.find_all(['th', 'td'])
        if len(cells) < 5:
            continue

        row_data = {h: c.get_text(strip=True) for h, c in zip(headers, cells)}
        player   = row_data.get('Player', '')
        if not player or player == 'Player':
            continue

        rows.append({
            'season':          year,
            'name_norm':       normalize_name(player),
            'college_norm':    normalize_college(slug.replace('-', ' ')),
            'college_slug':    slug,
            'defensive_solo':  safe_num(row_data.get('Solo', '')),
            'defensive_ast':   safe_num(row_data.get('Ast',  '')),
            'defensive_tot':   safe_num(row_data.get('Comb', '')),   # SR uses "Comb" not "Tot"
            'defensive_tfl':   safe_num(row_data.get('TFL',  '')),
            'defensive_sacks': safe_num(row_data.get('Sk',   '')),   # SR uses "Sk" not "Sacks"
            'defensive_pd':    safe_num(row_data.get('PD',   ''))
        })

    return rows

# ============================================================================
# Main
# ============================================================================

# Power 4 + Group 5 schools only — FCS/D2 schools are excluded because:
#   1. SR often lacks pages for them
#   2. They contribute <5% of NFL draft picks at defensive positions
#   3. Reduces page count from ~998 to ~250, making overnight run feasible
P4G5_SCHOOLS = {
    # SEC
    'alabama','georgia','lsu','florida','tennessee','auburn','texas am',
    'ole miss','mississippi state','arkansas','south carolina','kentucky',
    'vanderbilt','missouri','texas','oklahoma',
    # Big Ten
    'ohio state','michigan','penn state','iowa','wisconsin','michigan state',
    'minnesota','illinois','indiana','purdue','nebraska','northwestern',
    'maryland','rutgers',
    # Big 12
    'oklahoma state','texas tech','baylor','kansas state','iowa state',
    'west virginia','kansas','tcu',
    # ACC
    'clemson','miami fl','florida state','north carolina','nc state',
    'virginia tech','georgia tech','virginia','duke','boston college',
    'pittsburgh','louisville','syracuse','wake forest','miami',
    # Pac-12
    'southern california','ucla','oregon','washington','stanford',
    'california','arizona state','arizona','colorado','utah',
    'washington state','oregon state',
    # Group 5 — AAC
    'cincinnati','houston','memphis','south florida','central florida',
    'tulane','tulsa','east carolina','temple','navy',
    # Group 5 — Mountain West
    'boise state','san diego state','fresno state','nevada','utah state',
    'wyoming','new mexico','colorado state','hawaii','air force','san jose state',
    # Group 5 — MAC
    'toledo','western michigan','ohio','bowling green','northern illinois',
    'central michigan','eastern michigan','kent state','ball state','buffalo',
    # Group 5 — Sun Belt
    'louisiana','appalachian state','georgia southern','troy','arkansas state',
    # Group 5 — CUSA
    'marshall','western kentucky','middle tennessee','utep','florida atlantic',
    'uab','rice','utsa','old dominion',
    # Independents that produce significant draft picks
    'notre dame','army','brigham young',
    # Common nflreadr name variants
    'usc','penn st','ohio st','florida st','michigan st','mississippi st',
    'oklahoma st','oregon st','washington st','arizona st','colorado st',
    'iowa st','kansas st','boise st','fresno st','san jose st','kent st',
    'ball st','bowling green st','georgia tech','virginia tech','north carolina st',
}

# SR schools index returns 403 — slug map derived from names instead
slug_map  = {}
unmatched = load_unmatched()

# Build unique (college_norm, college_season) pairs — P4/G5 only
pairs = set()
skipped = 0
for _, row in unmatched.iterrows():
    cn = row['college_norm']
    if cn not in P4G5_SCHOOLS:
        skipped += 1
        continue
    for offset in [1, 2]:
        pairs.add((cn, int(row['season']) - offset))

print(f"Filtered to P4/G5 schools: {skipped} FCS/unknown prospects skipped")

# Match slugs
slug_pairs = []
for (college_norm, year) in sorted(pairs):
    slug = match_slug(college_norm, slug_map)
    slug_pairs.append((slug, college_norm, year))

# ── Filter by year if requested ─────────────────────────────────────────────
if args.year:
    slug_pairs = [(s, c, y) for s, c, y in slug_pairs if y == args.year]
    print(f"Filtered to year {args.year}: {len(slug_pairs)} pairs")
else:
    if args.year_from:
        slug_pairs = [(s, c, y) for s, c, y in slug_pairs if y >= args.year_from]
    if args.year_to:
        slug_pairs = [(s, c, y) for s, c, y in slug_pairs if y <= args.year_to]
    if args.year_from or args.year_to:
        print(f"Filtered to year range: {len(slug_pairs)} pairs")

# ── Cache state summary ──────────────────────────────────────────────────────
def cache_file_for(slug, year):
    return os.path.join(CACHE_DIR, f"{slug}_{year}.html")

cached   = [(s, c, y) for s, c, y in slug_pairs if os.path.exists(cache_file_for(s, y))]
uncached = [(s, c, y) for s, c, y in slug_pairs if not os.path.exists(cache_file_for(s, y))]

print(f"\nCache state: {len(cached)} already fetched, {len(uncached)} remaining")

if args.year:
    year_label = str(args.year)
elif args.year_from or args.year_to:
    year_label = f"{args.year_from or '?'}–{args.year_to or '?'}"
else:
    years_in_scope = sorted(set(y for _, _, y in slug_pairs))
    year_label = f"{min(years_in_scope)}–{max(years_in_scope)}" if years_in_scope else "all"
print(f"Targeting seasons: {year_label}")
print(f"Will fetch up to {args.max_pages} new pages this run")

# ── Sort: uncached first (makes --max-pages always make forward progress) ───
to_scrape = uncached[:args.max_pages]

if not to_scrape:
    print("\nAll pairs already cached — reading from cache only")
    to_scrape = cached   # still need to parse cached HTML into rows

# ── Scrape / read cache ──────────────────────────────────────────────────────
print(f"\nProcessing {len(to_scrape)} pairs ({len([p for p in to_scrape if not os.path.exists(cache_file_for(p[0], p[2]))])} new fetches)...")

all_rows = []
fetch_count = 0
for i, (slug, college_norm, year) in enumerate(to_scrape, 1):
    is_cached = os.path.exists(cache_file_for(slug, year))
    status = "cache" if is_cached else "fetch"
    if not is_cached:
        fetch_count += 1
    print(f"  [{i}/{len(to_scrape)}] {slug} {year} ({status})", end='  ')
    rows = scrape_school_defense(slug, year)
    print(f"{len(rows)} players")
    all_rows.extend(rows)

print(f"\nFetched {fetch_count} new pages | {len(uncached) - fetch_count} still remaining in queue")

# ── Merge with existing output if partial run ────────────────────────────────
if os.path.exists(OUTPUT) and fetch_count > 0:
    existing = pd.read_csv(OUTPUT)
    combined = pd.concat([existing, pd.DataFrame(all_rows)], ignore_index=True)
    # Deduplicate on (season, name_norm, college_slug)
    combined = combined.drop_duplicates(subset=['season', 'name_norm', 'college_slug'])
    df = combined[combined['defensive_tot'].notna() & (combined['defensive_tot'] > 0)].copy()
    print(f"Merged with existing output: {len(df):,} total player-seasons")
elif all_rows:
    df = pd.DataFrame(all_rows)
    df = df[df['defensive_tot'].notna() & (df['defensive_tot'] > 0)].copy()
    print(f"\nTotal: {len(df):,} player-seasons")
else:
    print("\nNo data retrieved")
    raise SystemExit(1)

# Sanity check
print("\nSample — top tacklers from 2012 Alabama:")
alabama = df[(df['college_slug'] == 'alabama') & (df['season'] == 2012)]
if not alabama.empty:
    print(alabama.nlargest(5, 'defensive_tot')[
        ['name_norm', 'defensive_tot', 'defensive_sacks', 'defensive_pd']
    ].to_string(index=False))

df.to_csv(OUTPUT, index=False)
print(f"\nSaved: {OUTPUT}  ({len(df):,} rows)")
if len(uncached) - fetch_count > 0:
    print(f"Resume: {len(uncached) - fetch_count} pairs still uncached — run again to continue")
else:
    print("All targeted pairs fetched. Next: re-run 01c_load_college_stats.R")
