package main

import (
	"bufio"
	"crypto/tls"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

const banner = "Kusanagi Night Ops: URL Scrapper"

var (
	// -------- HTML mode config --------
	mediaExt = map[string]bool{
		".png": true, ".jpg": true, ".jpeg": true, ".gif": true,
		".svg": true, ".webp": true, ".ico": true, ".mp4": true,
		".mov": true, ".wav": true,
	}
	scriptExt = map[string]bool{".js": true, ".mjs": true}
	docExt    = map[string]bool{
		".json": true, ".xml": true, ".yml": true, ".yaml": true,
		".pdf": true, ".txt": true, ".doc": true, ".docx": true, ".csv": true,
	}
	htmlExt = map[string]bool{".html": true, ".htm": true}

	frameworkSuffixes = []string{".bundle.js", ".chunk.js"}

	htmlCategoryFlags = map[string]string{
		"SCRIPTS":            "-s",
		"MEDIA":              "-md",
		"API / ENDPOINTS":    "-a",
		"DOCUMENTS / CONFIG": "-d",
		"HTML / FRAMEWORK":   "-ht",
		"OTHER":              "-O",
	}
	flagToCategoryHTML = func() map[string]string {
		m := map[string]string{}
		for k, v := range htmlCategoryFlags {
			m[v] = k
		}
		return m
	}()

	// -------- Network mode config --------
	networkTypeFlags = map[string]string{
		"Fetch/XHR": "-fx",
		"Doc":       "-d",
		"CSS":       "-css",
		"JS":        "-js",
		"Font":      "-f",
		"Img":       "-img",
		"Media":     "-md",
		"Manifest":  "-mf",
		"Socket":    "-s",
		"Wasm":      "-wasm",
		"Other":     "-O",
	}
	flagToNetType = func() map[string]string {
		m := map[string]string{}
		for t, f := range networkTypeFlags {
			m[f] = t
		}
		return m
	}()

	// Flags used only in HTML mode (for warning when mixed with -n).
	htmlModeOnlyFlags = map[string]bool{
		"-s":        true,
		"-md":       true,
		"-a":        true,
		"-d":        true,
		"-ht":       true,
		"-O":        true,
		"--no-media": true,
		"--full":     true,
	}

	// NOTE: Go's regexp (RE2) does not support lookbehind, so these are
	// simplified versions of the regexes. We rely on later logic
	// (maps/sets) to avoid duplication where possible.
	reHTTP       = regexp.MustCompile(`(?i)https?://[^\s'"<>]+`)
	reBLOB       = regexp.MustCompile(`(?i)blob:[^\s'"<>]+`)
	reSLASHSLASH = regexp.MustCompile(`(?i)//[^\s'"<>]+`)
	reHrefFrag   = regexp.MustCompile(`(?i)href=['"](#.+?)['"]`)

)

type htmlFilterConfig struct {
	includeCategories map[string]bool // nil means all
	excludeCategories map[string]bool
	noMediaMode       bool
	outputFile        string
	fullMode          bool
	searchTerms       []string // lowercase substrings
	insecureTLS       bool
}

func printHelp() {
	fmt.Println(strings.TrimSpace(`
Kusanagi Night Ops: URL Scrapper (Go HTML + Network Edition)

Run:
  go run kno-url.go        # dev
  ./kno-url                # compiled binary
  Main URL: <url> [flags]

Examples (HTML mode):
  Main URL: https://www.dailymotion.com/video/x9v4s9g
  Main URL: https://www.dailymotion.com/video/x9v4s9g -o results.txt
  Main URL: cnn.com -s -md
  Main URL: -u 10.8.1.4:80/video/x -a -d
  Main URL: cnn.com --search mp4,cdn
  Main URL: cnn.com --full

Examples (Network mode):
  Main URL: https://example.com -n -t 30
  Main URL: https://example.com -n -t 45s -fx -img
  Main URL: https://example.com -n --live -md --search mp4,cdn
  Main URL: https://example.com -n -t 1m -o net.txt

Night Ops:
  Main URL: --night-ops
  Main URL: https://example.com -n -t 60 --night-ops -sd 5m

Flags (HTML mode):
  -o <file>        Write output to file
  -s               Include SCRIPTS
  -md              Include MEDIA
  -a               Include API / ENDPOINTS
  -d               Include DOCUMENTS / CONFIG
  -ht              Include HTML / FRAMEWORK
  -O               Include OTHER
  --no-media       Flip category flags into EXCLUDES
  --search <terms> Comma-separated substrings; URL must match at least one term
  --full           Print full HTML (like curl). Ignores categories and --search.
  -u <url>         Explicit URL token
  --insecure       Skip TLS verification (useful for broken cert chains)

Flags (Network mode with -n):
  -n               Enable network capture mode
  -t <duration>    Duration (e.g. 30, 45s, 2m, 1h30m). Required unless --live.
  --live           Live mode; print requests as they happen until you Ctrl+C
  -o <file>        Write network summary to file
  --search <terms> Comma-separated substrings (mp4,cdn). URL must match at least one.
  Resource filters (can combine):
    -fx   Fetch/XHR
    -d    Doc
    -css  CSS
    -js   JS
    -f    Font
    -img  Img
    -md   Media
    -mf   Manifest
    -s    Socket
    -wasm Wasm
    -O    Other

Night Ops:
  --night-ops      Attempt local cleanup of this tool + .kno-url cache dirs
  -sd <duration>   Schedule night-ops after run (e.g. 5m, 1h30m). Requires --night-ops.

Help:
  -h, --help       Help

Notes:
  • If no HTML category flags are provided, all categories are included.
  • Sorting (HTML): within each category, URLs with extensions are grouped and
    sorted by extension (then URL). URLs without an extension are listed after.
  • Network mode requires playwright-go and browsers installed:
      go get github.com/playwright-community/playwright-go
      # then follow the repo docs to run "playwright install" for your platform.
`))
}

func normalizeURLCandidate(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return raw
	}
	if strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://") {
		return raw
	}
	if strings.HasPrefix(raw, "www.") {
		return "https://" + raw
	}
	// heuristic
	if strings.Contains(raw, ".") || strings.Contains(raw, ":") {
		return "https://" + raw
	}
	return raw
}

func parseMainInput(line string) (string, []string, bool) {
	tokens := strings.Fields(line)
	if len(tokens) == 0 {
		return "", nil, false
	}
	if len(tokens) == 1 && (tokens[0] == "-h" || tokens[0] == "--help") {
		return "HELP", nil, true
	}

	// -u <url>
	if tokens[0] == "-u" && len(tokens) >= 2 {
		return normalizeURLCandidate(tokens[1]), tokens[2:], true
	}

	// first non-flag token is URL
	if !strings.HasPrefix(tokens[0], "-") {
		return normalizeURLCandidate(tokens[0]), tokens[1:], true
	}

	// fallback scan
	for i, tok := range tokens {
		if strings.HasPrefix(tok, "http://") || strings.HasPrefix(tok, "https://") || strings.HasPrefix(tok, "www.") {
			u := normalizeURLCandidate(tok)
			args := append([]string{}, tokens[:i]...)
			args = append(args, tokens[i+1:]...)
			return u, args, true
		}
	}

	return "", tokens, false
}

func parseHTMLFilters(args []string) (htmlFilterConfig, error) {
	cfg := htmlFilterConfig{
		includeCategories: map[string]bool{},
		excludeCategories: map[string]bool{},
	}
	i := 0
	for i < len(args) {
		a := args[i]
		switch a {
		case "-o":
			if i+1 >= len(args) {
				return cfg, fmt.Errorf("Error: -o requires a filename")
			}
			cfg.outputFile = args[i+1]
			i += 2
		case "--no-media":
			cfg.noMediaMode = true
			i++
		case "--full":
			cfg.fullMode = true
			i++
		case "--search":
			if i+1 >= len(args) || strings.HasPrefix(args[i+1], "-") {
				return cfg, fmt.Errorf("Error: --search requires a value like 'mp4' or 'mp4,cdn'")
			}
			raw := args[i+1]
			parts := strings.Split(raw, ",")
			var terms []string
			for _, p := range parts {
				t := strings.ToLower(strings.TrimSpace(p))
				if t != "" {
					terms = append(terms, t)
				}
			}
			if len(terms) == 0 {
				return cfg, fmt.Errorf("Error: --search requires at least one non-empty term")
			}
			cfg.searchTerms = terms
			i += 2
		case "--insecure":
			cfg.insecureTLS = true
			i++
		default:
			if strings.HasPrefix(a, "-") {
				// category flags
				if cat, ok := flagToCategoryHTML[a]; ok {
					cfg.includeCategories[cat] = true
					i++
				} else if a == "-h" || a == "--help" || a == "-u" {
					// handled earlier
					i++
				} else {
					return cfg, fmt.Errorf("Error: Unknown flag: %s. Try -h for help.", a)
				}
			} else {
				// stray token; ignore
				i++
			}
		}
	}

	if cfg.noMediaMode {
		// In no-media mode, selected flags become exclusions; include becomes "all"
		for cat := range cfg.includeCategories {
			cfg.excludeCategories[cat] = true
		}
		cfg.includeCategories = nil
	} else {
		if len(cfg.includeCategories) == 0 {
			cfg.includeCategories = nil // all
		}
	}

	return cfg, nil
}

func fetchHTML(target string, insecure bool) (string, error) {
	client := &http.Client{
		Timeout: 20 * time.Second,
	}
	if insecure {
		client.Transport = &http.Transport{
			TLSClientConfig: &tls.Config{InsecureSkipVerify: true}, // best-effort; use only when needed
		}
	}

	req, err := http.NewRequest("GET", target, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", "KNO-URL-Scrapper/Go-HTML/1.0")

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	// decode as utf-8 best-effort
	return string(b), nil
}

func extractURLsFromHTML(htmlStr, base string) (map[string]bool, bool) {
	urls := map[string]bool{}
	blobPresent := false

	for _, m := range reHTTP.FindAllString(htmlStr, -1) {
		urls[m] = true
	}
	for _, m := range reBLOB.FindAllString(htmlStr, -1) {
		urls[m] = true
		blobPresent = true
	}
	// scheme-relative //...
	baseU, err := url.Parse(base)
	if err == nil {
		for _, m := range reSLASHSLASH.FindAllString(htmlStr, -1) {
			fixed := baseU.Scheme + ":" + m
			urls[fixed] = true
		}
	}

	// href="#fragment"
	for _, sub := range reHrefFrag.FindAllStringSubmatch(htmlStr, -1) {
		if len(sub) != 2 {
			continue
		}
		frag := sub[1]
		bu, err := url.Parse(base)
		if err != nil {
			continue
		}
		rel, err := url.Parse(frag)
		if err != nil {
			continue
		}
		joined := bu.ResolveReference(rel).String()
		urls[joined] = true
	}

	return urls, blobPresent
}

func categorizeURLHTML(u string) string {
	pu, err := url.Parse(u)
	if err != nil {
		return "OTHER"
	}
	p := pu.Path
	lp := strings.ToLower(p)

	for _, suf := range frameworkSuffixes {
		if strings.HasSuffix(lp, suf) {
			return "HTML / FRAMEWORK"
		}
	}

	ext := strings.ToLower(path.Ext(lp))

	if scriptExt[ext] {
		return "SCRIPTS"
	}
	if mediaExt[ext] {
		return "MEDIA"
	}
	if docExt[ext] {
		return "DOCUMENTS / CONFIG"
	}
	if htmlExt[ext] {
		return "HTML / FRAMEWORK"
	}

	joined := strings.ToLower(pu.Host + lp)
	if strings.Contains(lp, "/api/") || strings.Contains(joined, "graphql") {
		return "API / ENDPOINTS"
	}
	if ext == "" && pu.RawQuery != "" {
		return "API / ENDPOINTS"
	}

	return "OTHER"
}

func matchesSearch(u string, terms []string) bool {
	if len(terms) == 0 {
		return true
	}
	lu := strings.ToLower(u)
	for _, t := range terms {
		if strings.Contains(lu, t) {
			return true
		}
	}
	return false
}

func renderGrouped(grouped map[string][]string) string {
	var out []string
	order := []string{"SCRIPTS", "MEDIA", "API / ENDPOINTS", "DOCUMENTS / CONFIG", "HTML / FRAMEWORK", "OTHER"}

	for _, cat := range order {
		urls := grouped[cat]
		if len(urls) == 0 {
			continue
		}
		type pair struct {
			ext string
			u   string
		}
		var withExt []pair
		var noExt []string

		for _, u := range urls {
			pu, err := url.Parse(u)
			ext := ""
			if err == nil {
				ext = strings.ToLower(path.Ext(pu.Path))
			}
			if ext != "" {
				withExt = append(withExt, pair{ext: ext, u: u})
			} else {
				noExt = append(noExt, u)
			}
		}

		sort.Slice(withExt, func(i, j int) bool {
			if withExt[i].ext == withExt[j].ext {
				return withExt[i].u < withExt[j].u
			}
			return withExt[i].ext < withExt[j].ext
		})
		sort.Strings(noExt)

		out = append(out, cat)
		for _, p := range withExt {
			out = append(out, p.u)
		}
		for _, u := range noExt {
			out = append(out, u)
		}
		out = append(out, "")
	}

	return strings.TrimSpace(strings.Join(out, "\n"))
}

func handleHTML(urlStr string, args []string) {
	cfg, err := parseHTMLFilters(args)
	if err != nil {
		fmt.Println(err.Error())
		return
	}

	urlStr = normalizeURLCandidate(urlStr)

	fmt.Printf("[*] Fetching HTML from %s .\n", urlStr)
	htmlStr, err := fetchHTML(urlStr, cfg.insecureTLS)
	if err != nil {
		fmt.Printf("[-] Fetch error: %v\n", err)
		return
	}

	if cfg.fullMode {
		// --full ignores categories and search
		if cfg.outputFile != "" {
			if werr := os.WriteFile(cfg.outputFile, []byte(htmlStr), 0644); werr != nil {
				fmt.Printf("[-] Failed to write full HTML to %s: %v\n", cfg.outputFile, werr)
			} else {
				fmt.Printf("[*] Full HTML written to %s\n", cfg.outputFile)
			}
		}
		fmt.Println(htmlStr)
		return
	}

	urlSet, blobPresent := extractURLsFromHTML(htmlStr, urlStr)

	grouped := map[string][]string{
		"SCRIPTS":            {},
		"MEDIA":              {},
		"API / ENDPOINTS":    {},
		"DOCUMENTS / CONFIG": {},
		"HTML / FRAMEWORK":   {},
		"OTHER":              {},
	}

	for u := range urlSet {
		if !matchesSearch(u, cfg.searchTerms) {
			continue
		}
		cat := categorizeURLHTML(u)

		// include / exclude logic
		if cfg.includeCategories != nil && !cfg.includeCategories[cat] {
			continue
		}
		if cfg.excludeCategories[cat] {
			continue
		}
		grouped[cat] = append(grouped[cat], u)
	}

	text := renderGrouped(grouped)
	if text == "" {
		fmt.Println("[*] No URLs matched the selected filters.")
	} else {
		fmt.Println(text)
	}

	if cfg.outputFile != "" {
		if err := os.WriteFile(cfg.outputFile, []byte(text+"\n"), 0644); err != nil {
			fmt.Printf("[-] Failed to write to %s: %v\n", cfg.outputFile, err)
		} else {
			fmt.Printf("[*] Results written to %s\n", cfg.outputFile)
		}
	}

	if blobPresent {
		fmt.Println("\n[!] Detected blob: URLs in the HTML.")
		fmt.Println("    (Hint: use -n (network mode) if you want to capture blob: URLs at runtime.)")
	}
}

func parseDurationToSeconds(s string) (int, error) {
	s = strings.TrimSpace(strings.ToLower(s))
	if s == "" {
		return 0, fmt.Errorf("empty duration")
	}
	// pure integer (seconds)
	allDigits := true
	for _, r := range s {
		if r < '0' || r > '9' {
			allDigits = false
			break
		}
	}
	if allDigits {
		var total int
		for _, r := range s {
			total = total*10 + int(r-'0')
		}
		return total, nil
	}

	// accept things like "1h30m", "45s", "2m10s"
	var total int
	re := regexp.MustCompile(`(\d+)([hms])`)
	matches := re.FindAllStringSubmatch(s, -1)
	if len(matches) == 0 {
		return 0, fmt.Errorf("invalid duration: %s", s)
	}
	for _, m := range matches {
		if len(m) != 3 {
			continue
		}
		numStr := m[1]
		unit := m[2]
		val := 0
		for _, r := range numStr {
			val = val*10 + int(r-'0')
		}
		switch unit {
		case "h":
			total += val * 3600
		case "m":
			total += val * 60
		case "s":
			total += val
		}
	}
	if total <= 0 {
		return 0, fmt.Errorf("duration must be > 0")
	}
	return total, nil
}

func warnIfMixedHTMLFlagsInNetwork(args []string) {
	var found []string
	for _, a := range args {
		if htmlModeOnlyFlags[a] {
			found = append(found, a)
		}
	}
	if len(found) > 0 {
		fmt.Printf("[!] Warning: HTML mode flags %v were used with -n (network mode) and will be ignored.\n", found)
	}
}

func mapResourceTypeToGroup(rt, reqURL string) string {
	rt = strings.ToLower(rt)
	switch rt {
	case "xhr", "fetch":
		return "Fetch/XHR"
	case "document":
		return "Doc"
	case "stylesheet":
		return "CSS"
	case "script":
		return "JS"
	case "font":
		return "Font"
	case "image":
		return "Img"
	case "media":
		return "Media"
	case "manifest":
		return "Manifest"
	case "websocket", "eventsource":
		return "Socket"
	default:
		if strings.HasSuffix(strings.ToLower(reqURL), ".wasm") {
			return "Wasm"
		}
		return "Other"
	}
}

func runNetworkMode(urlStr string, args []string) {
	urlStr = normalizeURLCandidate(urlStr)
	warnIfMixedHTMLFlagsInNetwork(args)

	fmt.Println("[-] Network mode (-n) is not available in this build because Playwright is not linked.")
	fmt.Println()
	fmt.Println("    To enable network mode, you have two options:")
	fmt.Println()
	fmt.Println("    1) Build from source with the Playwright Go bindings:")
	fmt.Println("         go mod init example.com/kno-url        # if you don't have a go.mod yet")
	fmt.Println("         go get github.com/playwright-community/playwright-go")
	fmt.Println("         go mod tidy")
	fmt.Println("         go build -o kno-url kno-url.go")
	fmt.Println()
	fmt.Println("       Then follow the playwright-go documentation to install the browsers.")
	fmt.Println()
	fmt.Println("    2) Keep using this binary for HTML mode only (no -n).")
}


// -------- Night Ops cleanup --------

func runNightOpsCleanup() {
	exePath, err := os.Executable()
	if err != nil {
		fmt.Printf("[!] --night-ops: could not determine executable path: %v\n", err)
	} else {
		fmt.Printf("[*] --night-ops: attempting local cleanup for %s\n", exePath)
	}

	var scriptDir string
	if exePath != "" {
		scriptDir = filepath.Dir(exePath)
	}

	// remove .kno-url caches
	cacheDirs := []string{}
	if scriptDir != "" {
		cacheDirs = append(cacheDirs, filepath.Join(scriptDir, ".kno-url"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		cacheDirs = append(cacheDirs, filepath.Join(home, ".kno-url"))
	}

	for _, cdir := range cacheDirs {
		if cdir == "" {
			continue
		}
		if st, err := os.Stat(cdir); err == nil && st.IsDir() {
			if err := os.RemoveAll(cdir); err != nil {
				fmt.Printf("[!] Failed to remove cache directory (%s): %v\n", cdir, err)
			} else {
				fmt.Printf("[*] Removed cache directory %s\n", cdir)
			}
		}
	}

	// attempt to delete the binary itself
	if exePath != "" {
		if err := os.Remove(exePath); err != nil {
			fmt.Printf("[!] Could not delete executable (possibly locked by OS): %s (%v)\n", exePath, err)
		} else {
			fmt.Printf("[*] Removed executable %s\n", exePath)
		}
	}

	fmt.Println("[*] --night-ops: local cleanup complete (best effort).")
}

func confirmNightOps() bool {
	prompt := "[!] --night-ops will attempt to delete this binary and local .kno-url cache directories. Proceed? [y/N]: "
	fmt.Print(prompt)
	sc := bufio.NewScanner(os.Stdin)
	if !sc.Scan() {
		fmt.Println()
		return false
	}
	ans := strings.TrimSpace(strings.ToLower(sc.Text()))
	return ans == "y" || ans == "yes"
}

// -------- Top-level command handler --------

func indexOf(sl []string, target string) int {
	for i, v := range sl {
		if v == target {
			return i
		}
	}
	return -1
}

func handleCommand(line string) {
	urlStr, args, ok := parseMainInput(line)

	if ok && urlStr == "HELP" {
		printHelp()
		return
	}

	// Special case: only --night-ops
	if (!ok || urlStr == "") && len(args) == 1 && args[0] == "--night-ops" {
		if confirmNightOps() {
			runNightOpsCleanup()
			os.Exit(0)
		} else {
			fmt.Println("[*] --night-ops canceled; no cleanup performed.")
			return
		}
	}

	if !ok || urlStr == "" {
		fmt.Println("[-] No URL detected. Use -h or --help for usage, or use '--night-ops' alone for cleanup.")
		return
	}

	// Detect global flags
	nightOpsPresent := false
	for _, a := range args {
		if a == "--night-ops" {
			nightOpsPresent = true
			break
		}
	}

	// Handle -sd duration for scheduled night ops
	sdSeconds := 0
	sdIndex := indexOf(args, "-sd")
	if sdIndex != -1 {
		if sdIndex+1 >= len(args) || strings.HasPrefix(args[sdIndex+1], "-") {
			fmt.Println("Error: -sd requires a duration like '1h30m', '90s', or '1h 15m 30s'.")
			return
		}
		// collect duration tokens until next flag
		j := sdIndex + 1
		var durParts []string
		for j < len(args) && !strings.HasPrefix(args[j], "-") {
			durParts = append(durParts, args[j])
			j++
		}
		durStr := strings.Join(durParts, "")
		sec, err := parseDurationToSeconds(durStr)
		if err != nil || sec <= 0 {
			fmt.Printf("Error: invalid -sd duration: %s\n", strings.Join(durParts, " "))
			return
		}
		sdSeconds = sec
		// remove -sd and its value tokens from args
		newArgs := append([]string{}, args[:sdIndex]...)
		newArgs = append(newArgs, args[j:]...)
		args = newArgs
		if indexOf(args, "-sd") != -1 {
			fmt.Println("Error: -sd specified multiple times.")
			return
		}
	}

	if sdSeconds > 0 && !nightOpsPresent {
		fmt.Println("Error: -sd can only be used together with --night-ops.")
		return
	}

	// Full-mode flag detection (for conflict with -n)
	fullMode := false
	for _, a := range args {
		if a == "--full" {
			fullMode = true
			break
		}
	}

	networkMode := indexOf(args, "-n") != -1

	if fullMode && networkMode {
		fmt.Println("Error: --full cannot be used together with -n (network mode).")
		return
	}

	// If night-ops requested with a URL but no -sd, forbid mixing
	if nightOpsPresent && sdSeconds == 0 {
		fmt.Println("Error: --night-ops can't be ran along side other commands unless -sd is defined with a time to execute.")
		return
	}

	// Strip --night-ops from args before mode-specific parsing
	if nightOpsPresent {
		var filtered []string
		for _, a := range args {
			if a != "--night-ops" {
				filtered = append(filtered, a)
			}
		}
		args = filtered
	}

	// Mode dispatch
	if networkMode {
		// Remove -n before parsing network flags
		var netArgs []string
		for _, a := range args {
			if a != "-n" {
				netArgs = append(netArgs, a)
			}
		}
		runNetworkMode(urlStr, netArgs)
	} else {
		handleHTML(urlStr, args)
	}

	// If scheduled night ops: wait, then cleanup and exit
	if nightOpsPresent && sdSeconds > 0 {
		fmt.Printf("[*] --night-ops scheduled: sleeping for %d seconds before cleanup...\n", sdSeconds)
		time.Sleep(time.Duration(sdSeconds) * time.Second)
		if confirmNightOps() {
			runNightOpsCleanup()
		} else {
			fmt.Println("[*] --night-ops canceled at scheduled time; no cleanup performed.")
		}
		os.Exit(0)
	}
}

func main() {
	fmt.Println(banner)
	sc := bufio.NewScanner(os.Stdin)

	for {
		fmt.Print("Main URL: ")
		if !sc.Scan() {
			fmt.Println()
			return
		}
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			fmt.Println("[-] No URL detected. Use -h or --help for usage.")
			continue
		}
		handleCommand(line)
	}
}
