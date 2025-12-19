#!/usr/bin/env python3
"""
Kusanagi Night Ops: URL Scrapper (kno-url.py)

Usage (interactive):
    python3 kno-url.py
    Main URL: https://example.com -o results.txt -s -md

Modes:
    - default: HTML source scraping
    - network: -n with -t <duration> or --live
"""

import sys
import re
import os
import time
import shutil
import ssl
import importlib
import importlib.util
from urllib.parse import urlparse, urljoin
from urllib.request import urlopen, Request
from urllib.error import URLError, HTTPError

# --------- Python version guard ---------
if sys.version_info[0] < 3:
    sys.stderr.write("[-] Python 3.x required. Detected Python %d.%d\n" % sys.version_info[:2])
    sys.exit(1)


# --------- HTML mode category config ---------
MEDIA_EXT = {'.png', '.jpg', '.jpeg', '.gif', '.svg', '.webp', '.ico', '.mp4', '.mov', '.wav'}
SCRIPT_EXT = {'.js', '.mjs'}
DOC_EXT = {'.json', '.xml', '.yml', '.yaml', '.pdf', '.txt', '.doc', '.docx', '.csv'}
HTML_EXT = {'.html', '.htm'}
FRAMEWORK_SCRIPT_SUFFIXES = ('.bundle.js', '.chunk.js')
FONT_EXT = {'.woff', '.woff2', '.ttf', '.otf'}  # goes to OTHER per spec

CATEGORY_FLAGS_HTML = {
    'SCRIPTS': '-s',
    'MEDIA': '-md',
    'API / ENDPOINTS': '-a',
    'DOCUMENTS / CONFIG': '-d',
    'HTML / FRAMEWORK': '-ht',
    'OTHER': '-O',
}

FLAG_TO_CATEGORY_HTML = {v: k for k, v in CATEGORY_FLAGS_HTML.items()}

# --------- Network mode config ---------
NETWORK_TYPE_FLAGS = {
    'Fetch/XHR': '-fx',
    'Doc': '-d',
    'CSS': '-css',
    'JS': '-js',
    'Font': '-f',
    'Img': '-img',
    'Media': '-md',
    'Manifest': '-mf',
    'Socket': '-s',
    'Wasm': '-wasm',
    'Other': '-O',
}

FLAG_TO_NETTYPE = {v: k for k, v in NETWORK_TYPE_FLAGS.items()}

# --------- Flag universe for validation ---------
HTML_FLAG_SET = set(FLAG_TO_CATEGORY_HTML.keys()) | {'-o', '--no-media'}
NET_FLAG_SET = set(FLAG_TO_NETTYPE.keys()) | {'-o', '-t', '--live'}
GLOBAL_FLAG_SET = {'-n', '-sd', '--night-ops', '-h', '--help', '-u', '--search', '--full'}
ALL_FLAGS = HTML_FLAG_SET | NET_FLAG_SET | GLOBAL_FLAG_SET


def print_help():
    help_text = r"""
Kusanagi Night Ops: URL Scrapper

Interactive usage:
    python3 kno-url.py
    Main URL: <url> [flags]

Examples (HTML mode):
    Main URL: https://www.dailymotion.com/video/x9v4s9g
    Main URL: https://www.dailymotion.com/video/x9v4s9g -o results.txt
    Main URL: https://www.dailymotion.com/video/x9v4s9g -s -md
    Main URL: cnn.com -a -d
    Main URL: -u 10.8.1.4:80/video/x9v4s9g -s -md

URL parsing:
    • By default, the first non-flag token is treated as the URL.
      If it does not start with a scheme, https:// is assumed.
      Example: "cnn.com" -> "https://cnn.com"
    • You can explicitly specify the URL with -u:
      Main URL: -u 10.8.1.4:80/video/x -s -md

HTML mode flags (default mode, no -n):
    -o <file>      Output results to a file (both modes)
    -s             Include SCRIPTS
    -md            Include MEDIA
    -a             Include API / ENDPOINTS
    -d             Include DOCUMENTS / CONFIG
    -ht            Include HTML / FRAMEWORK
    -O             Include OTHER
    --no-media     Flip category flags into EXCLUDES (what NOT to include)
    --full         Dump full HTML like curl (no URL parsing, ignores categories and --search)

    Note: If no category flags are provided, all categories are included.
          With --no-media, any category flags become exclusions instead.

Network mode (DevTools-style network scraping):
    -n             Enable network mode
    One of:
        -t 30         Capture for 30 seconds
        -t 2m         Capture for 2 minutes
        -t 1m30s      Capture for 1 minute 30 seconds
        -t 90s        90 seconds
        --live        Capture live until Ctrl+C

    Network filtering flags (resource types):
        -fx           Fetch/XHR
        -d            Doc
        -css          CSS
        -js           JS
        -f            Font
        -img          Img
        -md           Media
        -mf           Manifest
        -s            Socket (WebSocket/EventSource)
        -wasm         Wasm
        -O            Other

    Notes:
        • Network mode requires the 'playwright' package.
        • Install browsers with: playwright install
        • If you mix -n with HTML-only category flags (-a, -ht, etc.), they are ignored
          and a warning is printed.

Search filter (applies to BOTH modes):
    --search <terms>
        Only include URLs whose string contains ANY of the given terms
        (case-insensitive substring match).

        Examples:
            --search mp4
            --search mp4,cdn
            --search api,v1,json

        This is combined with other filters (categories/types). URLs must match
        both the mode filters AND at least one search term.

Night Ops cleanup:
    --night-ops   Cleanup mechanic. Two modes:

                  1) Standalone immediate cleanup:
                     Main URL: --night-ops
                     - asks for confirmation
                     - attempts local cleanup of this tool's artifacts:
                       * delete __pycache__ in the script directory
                       * delete .kno-url cache directories (local + user)
                       * conditionally delete Playwright if it was installed
                         AFTER the first successful network-mode invocation
                         in this directory (see below)
                       * attempt to delete this script file (where OS permits)
                     - after cleanup, prints:
                       [+] Self-destruct complete. Exiting.
                     - then exits (no re-prompt).

                  2) Scheduled self-destruct with -sd when used alongside a URL:
                     Main URL: <url> [flags] --night-ops -sd <duration>
                     -sd <duration>  (e.g. 1h15m30s or "1h 15m 30s")
                     - no confirmation; runs operation, then sleeps for duration,
                       then runs the same cleanup as above, prints:
                       [+] Self-destruct complete. Exiting.
                       and exits.

Playwright tracking logic (network-mode only):
    • On first successful -n invocation (valid syntax: -t or --live) in a given
      directory:
        - If Playwright is present:
              .kno-url/playwright_preexisting.flag
        - If Playwright is NOT present:
              .kno-url/playwright_missing_at_start.flag

      (Invalid network usages like "nick.com -n" without -t/--live do NOT
       create any flags.)

    • If the .kno-url folder already exists and either flag is present
      (e.g., user reconnected and re-ran the tool), we do NOT overwrite
      or recreate those flags. We just reuse that state.

    • During --night-ops:
        - If playwright_preexisting.flag exists:
              → DO NOT delete Playwright (user had it before).
        - If playwright_missing_at_start.flag exists AND Playwright is now installed:
              → Best-effort delete:
                    * Playwright Python package directory
                    * ms-playwright browser bundle directory
        - All .kno-url tracking files are then removed as part of cleanup.

    This is best-effort only and does not remove system logs, remote logs,
    or forensic traces outside this directory.

General:
    -h, --help    Show this help
"""
    print(help_text.strip())


# --------- Utility: input parsing ---------
def normalize_url_candidate(raw: str) -> str:
    raw = raw.strip()
    if not raw:
        return raw
    if raw.startswith('http://') or raw.startswith('https://'):
        return raw
    if raw.startswith('www.'):
        return 'https://' + raw
    if '.' in raw or ':' in raw:
        return 'https://' + raw
    return raw


def parse_main_input(line):
    tokens = line.strip().split()
    if not tokens:
        return None, []

    if len(tokens) == 1 and tokens[0] in ('-h', '--help'):
        return 'HELP', []

    url = None
    url_index = None

    if tokens[0] == '-u' and len(tokens) >= 2:
        url = normalize_url_candidate(tokens[1])
        url_index = 1
        args = tokens[2:]
        return url, args

    if not tokens[0].startswith('-'):
        url_candidate = normalize_url_candidate(tokens[0])
        url = url_candidate
        url_index = 0
        args = tokens[1:]
        return url, args

    for i, tok in enumerate(tokens):
        if tok.startswith('http://') or tok.startswith('https://') or tok.startswith('www.'):
            url = normalize_url_candidate(tok)
            url_index = i
            break

    if url is None:
        return None, tokens

    args = tokens[:url_index] + tokens[url_index + 1:]
    return url, args


# --------- Utility: HTTP fetch (HTML mode) ---------
def fetch_html(url):
    try:
        req = Request(url, headers={'User-Agent': 'KNO-URL-Scrapper/1.0'})
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        with urlopen(req, timeout=20, context=ctx) as resp:
            charset = resp.headers.get_content_charset() or 'utf-8'
            content = resp.read()
            try:
                return content.decode(charset, errors='replace')
            except LookupError:
                return content.decode('utf-8', errors='replace')
    except HTTPError as e:
        print(f"[-] HTTP error fetching {url}: {e.code} {e.reason}")
    except URLError as e:
        print(f"[-] URL error fetching {url}: {e.reason}")
    except Exception as e:
        print(f"[-] Unexpected error fetching {url}: {e}")
    return None


# --------- Search helper ---------
def matches_search(url: str, search_terms):
    if not search_terms:
        return True
    ul = url.lower()
    return any(term in ul for term in search_terms)


# --------- HTML mode: URL extraction ---------
def extract_urls_from_html(html, base_url):
    urls = set()
    for m in re.findall(r'(?<!blob:)https?://[^\s\'"<>]+', html):
        urls.add(m)
    for m in re.findall(r'blob:[^\s\'"<>]+', html):
        urls.add(m)
    for m in re.findall(r'(?<!:)//[^\s\'"<>]+', html):
        parsed_base = urlparse(base_url)
        fixed = f"{parsed_base.scheme}:{m}"
        urls.add(fixed)
    for m in re.findall(r'href=[\'"](#.+?)[\'"]', html):
        frag_url = urljoin(base_url, m)
        urls.add(frag_url)
    return urls


def categorize_url_html(u):
    try:
        parsed = urlparse(u)
    except ValueError:
        return 'OTHER'

    path = parsed.path or ''
    lowered = path.lower()
    ext = os.path.splitext(lowered)[1]

    if lowered.endswith(FRAMEWORK_SCRIPT_SUFFIXES):
        return 'HTML / FRAMEWORK'
    if ext in SCRIPT_EXT:
        return 'SCRIPTS'
    if ext in MEDIA_EXT:
        return 'MEDIA'
    if ext in DOC_EXT:
        return 'DOCUMENTS / CONFIG'
    if ext in HTML_EXT:
        return 'HTML / FRAMEWORK'

    lowered_full = (parsed.netloc + lowered).lower()
    if '/api/' in lowered or 'graphql' in lowered_full:
        return 'API / ENDPOINTS'
    if ext == '' and parsed.query:
        return 'API / ENDPOINTS'

    return 'OTHER'


def filter_categories_html(args):
    include_categories = set()
    exclude_categories = set()
    output_file = None
    no_media_mode = False

    i = 0
    while i < len(args):
        arg = args[i]
        if arg == '-o' and i + 1 < len(args):
            output_file = args[i + 1]
            i += 2
            continue
        if arg == '--no-media':
            no_media_mode = True
            i += 1
            continue
        if arg in FLAG_TO_CATEGORY_HTML:
            cat = FLAG_TO_CATEGORY_HTML[arg]
            include_categories.add(cat)
            i += 1
            continue
        i += 1

    if no_media_mode:
        exclude_categories = include_categories
        include_categories = None
    if not include_categories and not no_media_mode:
        include_categories = None

    return include_categories, exclude_categories, output_file, no_media_mode


def print_html_results(grouped, output_file=None, blob_present=False):
    lines = []
    for category in ['SCRIPTS', 'MEDIA', 'API / ENDPOINTS',
                     'DOCUMENTS / CONFIG', 'HTML / FRAMEWORK', 'OTHER']:
        urls = grouped.get(category)
        if not urls:
            continue

        with_ext = []
        no_ext = []

        for u in urls:
            try:
                p = urlparse(u)
                path = p.path or ""
                ext = os.path.splitext(path.lower())[1]
            except ValueError:
                ext = ""
            if ext:
                with_ext.append((ext, u))
            else:
                no_ext.append(u)

        with_ext.sort(key=lambda t: (t[0], t[1]))
        no_ext_sorted = sorted(no_ext)

        lines.append(category)
        for ext, u in with_ext:
            lines.append(u)
        for u in no_ext_sorted:
            lines.append(u)
        lines.append('')

    text = "\n".join(lines).strip()
    if text:
        print(text)
    else:
        print("[*] No URLs matched the selected filters.")

    if output_file:
        try:
            with open(output_file, 'w', encoding='utf-8') as f:
                f.write(text + "\n")
            print(f"[*] Results written to {output_file}")
        except Exception as e:
            print(f"[-] Failed to write to {output_file}: {e}")

    if blob_present:
        print("\n[!] Detected blob: URLs in the HTML.")
        print("    Consider using network mode (-n) to see beyond blob: URLs.")
        print("    Hint: use -h or --help for network mode options.")


# --------- Network mode: duration parsing ---------
def parse_duration_to_seconds(s):
    s = s.strip().lower()
    if not s:
        return None
    if s.isdigit():
        return int(s)

    pattern = r'(\d+)([hms]?)'
    matches = re.findall(pattern, s)
    if not matches:
        return None

    total = 0
    for num, unit in matches:
        n = int(num)
        if unit == 'h':
            total += n * 3600
        elif unit == 'm':
            total += n * 60
        else:
            total += n
    return total if total > 0 else None


def warn_if_mixed_html_flags_in_network(args):
    html_only_flags = set(FLAG_TO_CATEGORY_HTML.keys()) | {'--no-media', '--full'}
    used_html_flags = html_only_flags.intersection(args)
    if used_html_flags:
        print("[!] Warning: Detected HTML-mode-only flags in network mode:")
        print(f"    {', '.join(sorted(used_html_flags))}")
        print("    These will be ignored in network mode (except --full, which is invalid with -n).")


# --------- Playwright state helpers ---------
def init_playwright_state():
    """
    On first valid -n invocation (per script directory), record whether
    Playwright existed or not:
        .kno-url/playwright_preexisting.flag
        .kno-url/playwright_missing_at_start.flag

    If .kno-url already exists AND either flag exists (e.g. user reconnected
    and re-ran the tool), we assume the state is already set and do nothing.
    """
    try:
        script_path = os.path.abspath(__file__)
        script_dir = os.path.dirname(script_path)
        state_dir = os.path.join(script_dir, '.kno-url')

        pre_flag = os.path.join(state_dir, 'playwright_preexisting.flag')
        missing_flag = os.path.join(state_dir, 'playwright_missing_at_start.flag')

        # If folder + any flag exists, reuse it and do nothing.
        if os.path.isdir(state_dir) and (os.path.exists(pre_flag) or os.path.exists(missing_flag)):
            return

        os.makedirs(state_dir, exist_ok=True)

        try:
            spec = importlib.util.find_spec("playwright")
        except Exception:
            spec = None

        if spec is not None:
            open(pre_flag, 'w').close()
        else:
            open(missing_flag, 'w').close()
    except Exception:
        pass


def find_playwright_package_dir():
    try:
        spec = importlib.util.find_spec("playwright")
        if not spec or not spec.origin:
            return None
        return os.path.dirname(spec.origin)
    except Exception:
        return None


def get_ms_playwright_dir():
    home = os.path.expanduser('~')
    env_path = os.environ.get("PLAYWRIGHT_BROWSERS_PATH")
    if env_path:
        return env_path
    if os.name == 'nt':
        base = os.environ.get("LOCALAPPDATA") or os.path.join(home, "AppData", "Local")
        return os.path.join(base, "ms-playwright")
    elif sys.platform == "darwin":
        return os.path.join(home, "Library", "Caches", "ms-playwright")
    else:
        return os.path.join(home, ".cache", "ms-playwright")


def maybe_delete_playwright_if_installed_after(script_dir):
    state_dir = os.path.join(script_dir, '.kno-url')
    pre_flag = os.path.join(state_dir, 'playwright_preexisting.flag')
    missing_flag = os.path.join(state_dir, 'playwright_missing_at_start.flag')

    preexisting = os.path.isfile(pre_flag)
    missing_at_start = os.path.isfile(missing_flag)

    if not missing_at_start or preexisting:
        return

    try:
        spec = importlib.util.find_spec("playwright")
    except Exception:
        spec = None

    if spec is None:
        return

    print("[*] Detected Playwright installed after first valid network-mode use; attempting cleanup...")

    pkg_dir = find_playwright_package_dir()
    if pkg_dir and os.path.isdir(pkg_dir):
        try:
            shutil.rmtree(pkg_dir)
            print(f"[*] Removed Playwright package at {pkg_dir}")
        except Exception as e:
            print(f"[!] Failed to remove Playwright package at {pkg_dir}: {e}")

    browsers_dir = get_ms_playwright_dir()
    if browsers_dir and os.path.isdir(browsers_dir):
        try:
            shutil.rmtree(browsers_dir)
            print(f"[*] Removed Playwright browsers at {browsers_dir}")
        except Exception as e:
            print(f"[!] Failed to remove Playwright browsers at {browsers_dir}: {e}")


# --------- Network mode implementation (Playwright) ---------
def run_network_mode(url, args, search_terms=None):
    duration_seconds = None
    live_mode = False
    output_file = None
    selected_types = set()

    i = 0
    while i < len(args):
        arg = args[i]
        if arg == '-o' and i + 1 < len(args):
            output_file = args[i + 1]
            i += 2
            continue
        if arg == '-t' and i + 1 < len(args):
            duration_seconds = parse_duration_to_seconds(args[i + 1])
            if duration_seconds is None:
                print(f"[-] Invalid duration: {args[i + 1]!r}")
                return
            i += 2
            continue
        if arg == '--live':
            live_mode = True
            i += 1
            continue
        if arg in FLAG_TO_NETTYPE:
            selected_types.add(FLAG_TO_NETTYPE[arg])
            i += 1
            continue
        i += 1

    if not live_mode and duration_seconds is None:
        print("[-] Network mode (-n) requires either -t <duration> or --live.")
        return

    init_playwright_state()
    warn_if_mixed_html_flags_in_network(args)

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("[-] Network mode requires the 'playwright' package.")
        print("    Install with: pip install playwright")
        print("    Then install a browser with: playwright install")
        return

    def map_resource_type(rt, url_str):
        rt = rt.lower()
        if rt in ('xhr', 'fetch'):
            return 'Fetch/XHR'
        if rt == 'document':
            return 'Doc'
        if rt == 'stylesheet':
            return 'CSS'
        if rt == 'script':
            return 'JS'
        if rt == 'font':
            return 'Font'
        if rt == 'image':
            return 'Img'
        if rt == 'media':
            return 'Media'
        if rt == 'manifest':
            return 'Manifest'
        if rt in ('websocket', 'eventsource'):
            return 'Socket'
        if url_str.lower().endswith('.wasm'):
            return 'Wasm'
        return 'Other'

    captured = {}

    def should_keep_type(tname):
        if not selected_types:
            return True
        return tname in selected_types

    print(f"[*] Starting network capture for {url}")
    if live_mode:
        print("[*] Live mode: press Ctrl+C to stop.")
    else:
        print(f"[*] Capture duration: {duration_seconds} seconds")

    try:
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            context = browser.new_context()
            page = context.new_page()

            def on_request(request):
                rt = request.resource_type
                u = request.url
                tname = map_resource_type(rt, u)
                if not should_keep_type(tname):
                    return
                if not matches_search(u, search_terms):
                    return
                captured.setdefault(tname, set()).add(u)
                if live_mode:
                    print(f"[{tname}] {u}")

            page.on("request", on_request)
            page.goto(url, wait_until="networkidle")

            if live_mode:
                try:
                    while True:
                        time.sleep(0.5)
                except KeyboardInterrupt:
                    print("\n[*] Live capture stopped by user.")
            else:
                time.sleep(duration_seconds)

            browser.close()
    except Exception as e:
        print(f"[-] Network mode failed: {e}")
        return

    lines = []
    for tname in ['Fetch/XHR', 'Doc', 'CSS', 'JS', 'Font',
                  'Img', 'Media', 'Manifest', 'Socket', 'Wasm', 'Other']:
        urls = captured.get(tname)
        if not urls:
            continue
        lines.append(tname)
        for u in sorted(urls):
            lines.append(u)
        lines.append('')

    text = "\n".join(lines).strip()
    if text:
        print(text)
    else:
        print("[*] No network requests matched the selected filters.")

    if output_file:
        try:
            with open(output_file, 'w', encoding='utf-8') as f:
                f.write(text + "\n")
            print(f"[*] Network results written to {output_file}")
        except Exception as e:
            print(f"[-] Failed to write to {output_file}: {e}")


# --------- Night Ops cleanup ---------
def run_night_ops_cleanup():
    script_path = os.path.abspath(__file__)
    script_dir = os.path.dirname(script_path)

    print("[*] --night-ops: attempting local cleanup of tool artifacts...")

    maybe_delete_playwright_if_installed_after(script_dir)

    pycache_dir = os.path.join(script_dir, '__pycache__')
    if os.path.isdir(pycache_dir):
        try:
            shutil.rmtree(pycache_dir)
            print(f"[*] Removed __pycache__ at {pycache_dir}")
        except Exception as e:
            print(f"[!] Failed to remove __pycache__ ({pycache_dir}): {e}")

    cache_dirs = [
        os.path.join(script_dir, '.kno-url'),
        os.path.join(os.path.expanduser('~'), '.kno-url'),
    ]
    for cdir in cache_dirs:
        if os.path.isdir(cdir):
            try:
                shutil.rmtree(cdir)
                print(f"[*] Removed cache directory {cdir}")
            except Exception as e:
                print(f"[!] Failed to remove cache directory ({cdir}): {e}")

    try:
        os.remove(script_path)
        print(f"[*] Removed script file {script_path}")
    except PermissionError:
        print(f"[!] Could not delete script file (possibly locked by OS): {script_path}")
    except Exception as e:
        print(f"[!] Failed to delete script file {script_path}: {e}")

    print("[*] --night-ops: local cleanup complete (best effort).")


def confirm_night_ops():
    prompt = "[!] --night-ops will attempt to delete this script and local cache directories. Proceed? [y/N]: "
    try:
        ans = input(prompt).strip().lower()
    except (EOFError, KeyboardInterrupt):
        print()
        return False
    return ans in ('y', 'yes')


# --------- HTML mode runner ---------
def run_html_mode(url, args, search_terms=None, full_mode=False):
    if full_mode:
        _, _, output_file, _ = filter_categories_html(args)
        print(f"[*] Fetching HTML from {url} ...")
        html = fetch_html(url)
        if html is None:
            return
        if output_file:
            try:
                with open(output_file, 'w', encoding='utf-8') as f:
                    f.write(html)
                print(f"[*] Full HTML written to {output_file}")
            except Exception as e:
                print(f"[-] Failed to write full HTML to {output_file}: {e}")
        print(html)
        return

    include_categories, exclude_categories, output_file, no_media_mode = filter_categories_html(args)

    print(f"[*] Fetching HTML from {url} ...")
    html = fetch_html(url)
    if html is None:
        return

    urls = extract_urls_from_html(html, url)
    blob_present = any(u.startswith('blob:') for u in urls)

    grouped = {
        'SCRIPTS': [],
        'MEDIA': [],
        'API / ENDPOINTS': [],
        'DOCUMENTS / CONFIG': [],
        'HTML / FRAMEWORK': [],
        'OTHER': [],
    }

    for u in urls:
        if not matches_search(u, search_terms):
            continue
        cat = categorize_url_html(u)
        if include_categories is not None and cat not in include_categories:
            continue
        if cat in exclude_categories:
            continue
        grouped.setdefault(cat, []).append(u)

    print_html_results(grouped, output_file=output_file, blob_present=blob_present)


# --------- Main per-command handler ---------
def handle_command(line):
    url, args = parse_main_input(line)

    if url == 'HELP':
        print_help()
        return

    if url is None and args == ['--night-ops']:
        if confirm_night_ops():
            run_night_ops_cleanup()
            print("[+] Self-destruct complete. Exiting.")
            sys.exit(0)
        else:
            print("[*] --night-ops canceled; no cleanup performed.")
        return

    if url is None:
        print("[-] No URL detected. Use -h or --help for usage, or use '--night-ops' alone for cleanup.")
        return

    search_terms = None
    if '--search' in args:
        idx = args.index('--search')
        if idx + 1 >= len(args) or args[idx + 1].startswith('-'):
            print("Error: --search requires a value, e.g. '--search mp4' or '--search mp4,cdn'.")
            return
        raw_terms = args[idx + 1]
        terms = [t.strip().lower() for t in raw_terms.split(',') if t.strip()]
        if not terms:
            print("Error: --search requires at least one non-empty term.")
            return
        search_terms = terms
        args = args[:idx] + args[idx + 2:]

    full_mode = False
    if '--full' in args:
        full_mode = True
        args = [a for a in args if a != '--full']

    night_ops_present = '--night-ops' in args
    sd_seconds = None
    if '-sd' in args:
        idx = args.index('-sd')
        dur_tokens = []
        j = idx + 1
        while j < len(args) and not args[j].startswith('-'):
            dur_tokens.append(args[j])
            j += 1
        if not dur_tokens:
            print("Error: -sd requires a duration like '1h30m', '90s', or '1h 15m 30s'.")
            return
        dur_str = "".join(dur_tokens)
        sd_seconds = parse_duration_to_seconds(dur_str)
        if sd_seconds is None:
            print(f"Error: invalid -sd duration: {' '.join(dur_tokens)}")
            return
        args = args[:idx] + args[j:]
        if '-sd' in args:
            print("Error: -sd specified multiple times.")
            return

    if sd_seconds is not None and not night_ops_present:
        print("Error: -sd can only be used together with --night-ops.")
        return

    unknown = [tok for tok in args
               if tok.startswith('-') and tok not in ALL_FLAGS and tok != '--night-ops']
    if unknown:
        print(f"Error: Unknown flag(s): {' '.join(unknown)}. Try -h to see the full flag list.")
        return

    if night_ops_present and sd_seconds is None and url is not None:
        print("Error: --night-ops can't be ran along side other commands unless -sd is defined with a time to execute")
        return

    if night_ops_present:
        args = [a for a in args if a != '--night-ops']

    network_mode = '-n' in args
    if full_mode and network_mode:
        print("Error: --full is only supported in HTML mode and can't be combined with -n.")
        return

    if network_mode:
        args = [a for a in args if a != '-n']
        run_network_mode(url, args, search_terms=search_terms)
    else:
        run_html_mode(url, args, search_terms=search_terms, full_mode=full_mode)

    if night_ops_present and sd_seconds is not None:
        print(f"[*] --night-ops scheduled via -sd, sleeping for {sd_seconds} seconds before cleanup...")
        try:
            time.sleep(sd_seconds)
        except KeyboardInterrupt:
            print("\n[!] Sleep interrupted; cleanup aborted.")
            return
        run_night_ops_cleanup()
        print("[+] Self-destruct complete. Exiting.")
        sys.exit(0)


# --------- Main REPL loop ---------
def main():
    print("Kusanagi Night Ops: URL Scrapper")
    while True:
        try:
            line = input("Main URL: ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            break

        if not line:
            print("[-] No URL detected. Use -h or --help for usage, or use '--night-ops' alone for cleanup.")
            continue

        handle_command(line)


if __name__ == "__main__":
    main()
