# Kusanagi Night Ops – URL Scraper

[English] | [日本語](README.ja.md)

`kno-url` is a family of interactive URL utilities used in Kusanagi Night Ops for **authorized offensive security**, **red teaming**, and **adversary simulation**.

All implementations share the same core idea:

- Prompt with `Main URL:`
- Take a URL plus flags
- Run in either **HTML mode** (page fetch + URL extraction) or **network mode** (DevTools-style capture, where supported)
- Optionally perform a **Night Ops self-destruct** to clean up local artifacts

This README applies to:

- `kno-url.c` – C Edition (HTML + Night Ops, network stub)
- `kno-url.go` – Go Edition (HTML + full network mode)
- `kno-url-with-network-mode.go` – Go Edition (HTML + full network mode, single-file variant)
- `kno-url.py` – Python Edition (HTML + full network mode)
- `kno-url.ps1` – PowerShell Edition (HTML + Night Ops, gated network stub)

For community expectations and behavioral rules, see `CODE_OF_CONDUCT.md`.

---

## 1. What kno-url Does

At a high level, **kno-url is a URL “scrapper” REPL**:

- You start the tool (in your language of choice).
- It prints a banner and then repeatedly prompts:


  Main URL: <url> [flags]


* For each line you enter, it parses the tokens and decides:

  * HTML mode (default), or
  * Network mode (if `-n` is present and implemented for that edition), or
  * Night Ops cleanup (if `--night-ops` is used)

The tool then:

* Fetches and parses the page (HTML mode), **or**
* Uses a real browser via Playwright to capture DevTools network events (network mode, where implemented),
* Applies category / resource-type filters and optional substring search filters,
* Prints a categorized URL list (and optionally writes it to a file),
* And optionally schedules or runs a local cleanup/self-destruct.

---

## 2. Tool Variants

All variants are conceptually compatible but differ in implementation detail and capabilities:

* **C Edition – `kno-url.c`**

  * Uses `libcurl` to fetch HTML.
  * Supports **HTML mode** (categories, `--search`, `--full`, `-o`).
  * Supports **`--night-ops` + `-sd`** self-destruct.
  * The `-n` flag exists only as a **red-team warning stub**:

    * Shows a “noisy / not stealthy” warning.
    * Then explains that **network mode is not supported** in this edition.

* **Go Edition – `kno-url.go`**

  * Go binary with **HTML mode + full network mode**.
  * Network mode is implemented via **`playwright-go`** and a local Playwright browser install.
  * Supports `--night-ops` and `-sd` for self-destruct.

* **Go Edition (network-mode file) – `kno-url-with-network-mode.go`**

  * Single-file Go entrypoint with the same **HTML + network mode** semantics.
  * Also uses **`playwright-go`**.
  * Choose whichever Go entrypoint fits your build style; behavior is aligned.

* **Python Edition – `kno-url.py`**

  * Python 3 script with **HTML mode + full network mode** using **Python Playwright**.
  * Implements more detailed **Playwright tracking** in `.kno-url/` to know whether Playwright existed before the first network run (for cleanup logic in `--night-ops`).
  * Provides a rich help text explaining how network-mode and self-destruct behave.

* **PowerShell Edition – `kno-url.ps1`**

  * PowerShell script with **HTML mode + Night Ops** and a **gated network stub**.
  * Network mode:

    * Performs environment checks for **.NET**, **Playwright CLI**, browser bundles, and GUI availability.
    * Emphasizes that real browser automation is noisy and should only be used in controlled environments.
    * In this edition, **no actual network capture** is performed; it’s primarily for gating, warnings, and UX parity.
  * Implements `--night-ops` and `-sd` with Windows-friendly cleanup behavior.

---

## 3. Modes & Core Concepts

### 3.1 Interactive REPL

All editions behave as an interactive loop:

```text
Kusanagi Night Ops: URL Scrapper (<Language> Edition)

Main URL: <url> [flags]
```

* Empty lines → “No URL detected. Use -h or --help for usage.”
* `-h` or `--help` → language-specific help text and examples.
* `--night-ops` (with or without `-sd`) → self-destruct flow.

---

### 3.2 HTML Mode (Default)

**HTML mode** is used when **`-n` is not present**.

Typical input:

```text
Main URL: https://example.com -s -md --search mp4,cdn -o results.txt
```

Typical behavior:

1. **URL normalization**

   * If the URL doesn’t start with `http://` or `https://`, `https://` is assumed.
   * Bare domains or host:port strings are normalized (e.g., `cnn.com` → `https://cnn.com`).

2. **Fetch HTML** using `curl`/`net/http`/`requests`/PowerShell equivalents.

3. **Extract URLs** and assign them to categories such as:

   * `-s` – **SCRIPTS**
   * `-md` – **MEDIA**
   * `-a` – **API / ENDPOINTS**
   * `-d` – **DOCUMENTS / CONFIG**
   * `-ht` – **HTML / FRAMEWORK**
   * `-O` – **OTHER**

4. **Apply category logic**:

   * If **no category flags** are given, **all categories** are included.
   * `--no-media` (HTML-only) flips selected categories into **exclusions** instead of inclusions.

5. **Apply search filter** (see below).

6. **Print results**, grouped by category and often sorted by file extension and URL.

Common HTML flags (exact spelling is shared across editions):

* `-s -md -a -d -ht -O` – category filters
* `--no-media` – treat any selected categories as **exclusions**
* `--search <terms>` – comma-separated substring filter
* `--full` – dump full HTML (like `curl`), ignoring categories and `--search`
* `-o <file>` – write output to a file

---

### 3.3 Network Mode (`-n`)

**Network mode** is available in:

* `kno-url.go`
* `kno-url-with-network-mode.go`
* `kno-url.py`

and **stubbed with warnings only** in:

* `kno-url.c`
* `kno-url.ps1` (PowerShell emphasizes Playwright requirements and noise, but does not capture traffic)

#### Behavior (Go + Python editions)

When `-n` is present and properly configured:

* The tool uses **Playwright** to open the target URL in a browser.

* It captures **DevTools-style network events** for a given duration or until interrupted.

* Resource types can be filtered with flags such as:

  * `-fx` – Fetch/XHR
  * `-d` – Document
  * `-css` – CSS
  * `-js` – JavaScript
  * `-f` – Font
  * `-img` – Images
  * `-md` – Media
  * `-mf` – Manifest
  * `-s` – Socket/WebSocket
  * `-wasm` – WebAssembly
  * `-O` – Other

* Duration is set via `-t <duration>` (e.g. `30`, `45s`, `2m`, `1h30m`) or `--live` (run until Ctrl+C).

* `--search <terms>` still applies, filtering by substring against captured URLs.

* `-o <file>` can be used to write a summary to disk.

**Important:** These modes are noisy and use a full browser stack. They are **not stealthy** and are meant for **labs and authorized testing only**.

---

### 3.4 Search Filter (`--search`)

In both HTML and network modes:

* `--search mp4,cdn,api`

  * Splits terms by comma.
  * Keeps URLs that contain **at least one** term (case-insensitive substring match).
  * Combines with other filters: a URL must pass both the **mode filters** and the **search terms**.

---

### 3.5 Night Ops Self-Destruct (`--night-ops`, `-sd`)

All editions implement a **Night Ops cleanup mechanic**, with two patterns:

1. **Standalone immediate cleanup**

   ```text
   Main URL: --night-ops
   ```

   Typical behavior:

   * Ask for confirmation.
   * Attempt local cleanup of tool artifacts:

     * `.kno-url` cache and tracking directories.
     * `__pycache__` and related Python artifacts (Python/PowerShell).
     * Playwright-related directories **only if** the tool tracked that they were installed after the first network run (Python/PowerShell).
     * The tool binary or script itself (best-effort; OS-dependent).
   * Print a success message and exit.

2. **Scheduled self-destruct with `-sd`**

   ```text
   Main URL: <url> [flags] --night-ops -sd <duration>
   ```

   * Runs the normal HTML / network operation.
   * Sleeps for the given duration (e.g., `90s`, `5m`, `1h15m30s`, or spaced forms like `"1h 15m 30s"`).
   * Performs the same cleanup as above **without confirmation**.
   * Exits.

All cleanup is **local and best-effort**. It does **not** wipe system logs, remote logs, or other forensic traces outside the local directories.

---

## 4. Language-Specific Dependencies

### C Edition (`kno-url.c`)

* Requires a C toolchain and `libcurl`.
* Build example:

  ```bash
  cc -O2 -o kno-url-c kno-url.c -lcurl
  ./kno-url-c
  ```

### Go Editions (`kno-url.go`, `kno-url-with-network-mode.go`)

* Requires Go toolchain.

* Network mode requires:

  * `playwright-go`
  * Playwright browsers installed (`playwright install` from the Playwright CLI for your platform).

* Build example:

  ```bash
  # HTML + network mode
  go build -o kno-url-go kno-url.go

  # Single-file network-mode variant
  go build -o kno-url-net kno-url-with-network-mode.go

  ./kno-url-go
  ```

### Python Edition (`kno-url.py`)

* Requires Python 3.

* For network mode:

  ```bash
  pip install playwright
  playwright install
  ```

* Run:

  ```bash
  python3 kno-url.py
  ```

### PowerShell Edition (`kno-url.ps1`)

* Runs on Windows PowerShell or PowerShell Core.

* For network **gating** and warnings, it checks:

  * `.NET` availability
  * Playwright CLI (`dotnet tool install --global Microsoft.Playwright.CLI`)
  * `playwright install` (browser bundles)
  * GUI availability

* Run:

  ```powershell
  powershell -ExecutionPolicy Bypass -File .\kno-url.ps1
  # or
  pwsh -File ./kno-url.ps1
  ```

---

## 5. Quick Start Examples

### HTML Mode (any edition)

```text
Main URL: https://www.example.com/video/x9v4s9g -s -md -o urls.txt
Main URL: cnn.com --search mp4,cdn
Main URL: -u 10.8.1.4:80/video/x -a -d
Main URL: https://example.com --full
```

### Network Mode (Go / Python)

```text
Main URL: https://example.com -n -t 30
Main URL: https://example.com -n -t 45s -fx -img
Main URL: https://example.com -n --live -md --search mp4,cdn
Main URL: https://example.com -n -t 1m -o net.txt
```

### Night Ops

```text
# Immediate self-destruct
Main URL: --night-ops

# Run then self-destruct after 5 minutes
Main URL: https://example.com -s -md --night-ops -sd 5m
```

---

## 6. Safety, Scope, and Legal Notes

`kno-url` is designed for:

* Personal labs and controlled training environments.
* Systems and applications you own.
* Systems where you have **explicit, written authorization** to test.

It must **not** be used for:

* Unauthorized access, exploitation, or data theft.
* Ransomware or extortion operations.
* Any activity that violates law, contracts, or organizational policies.

If you are unsure whether a target or scenario is in scope, treat it as **out of scope** until you have clear approval.

For community rules and reporting, see `CODE_OF_CONDUCT.md`.

---

## 7. Files in This Folder

* `kno-url.c`
  C Edition – HTML mode, `--search`, `--full`, `-o`, Night Ops, network stub.

* `kno-url.go`
  Go Edition – HTML + network mode, Night Ops.

* `kno-url-with-network-mode.go`
  Go Edition (single-file) – HTML + network mode, Night Ops.

* `kno-url.py`
  Python Edition – HTML + network mode, Night Ops, Playwright tracking logic.

* `kno-url.ps1`
  PowerShell Edition – HTML mode, Night Ops, network gating/warnings.

---

If you’d like, next step I can mirror this into a Japanese `README.ja.md` that keeps the same section structure and tone as your Code of Conduct.
```
