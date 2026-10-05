/*
 * pm3scan — SDL2 GUI front-end for the Iceman Proxmark3 client on TrimUI handhelds.
 *
 * One-touch HF (13.56 MHz) and LF (125 kHz) scanning: forks the proxmark3
 * client, streams its output, and surfaces the interesting lines as findings.
 *
 * The client is the authority on what a tag is; this app never re-implements
 * protocol logic, it drives `proxmark3 -c "hf search" / "lf search"` and
 * presents the result. Raw client output is kept visible in the log pane so
 * nothing is hidden if the keyword extraction misses a line.
 *
 * Non-interactive modes exist so the GUI can be verified over SSH:
 *   --probe                 print SDL video drivers / display mode, exit
 *   --scan-once hf|lf       run one scan without GUI, print output, exit
 *   --run-seconds N         quit automatically after N seconds
 *   --auto-scan hf|lf       start a scan immediately
 *   --screenshot FILE.bmp   save the last rendered frame
 *   --log FILE              append diagnostics to FILE
 */
#define _GNU_SOURCE
#include <SDL2/SDL.h>
#include <SDL2/SDL_ttf.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* ------------------------------------------------------------------ config */

#define MAX_LOG      400
#define LINE_MAX     512
#define MAX_FIND      48
#define RAW_CAP    (192 * 1024)

/* Where the Iceman client is looked for, in order:
 *   1. $PM3_BIN or --pm3
 *   2. <app dir>/pm3/proxmark3     -- self-contained copy on the SD card, so the
 *                                     whole install can be done by copying files
 *   3. the default below           -- internal storage, where install.sh puts it
 * The app directory is the one holding this executable, so layout 2 travels with
 * the app: unplug the card, drop it in another handheld, and it still works. */
#define DEFAULT_PM3  "/mnt/UDISK/pm3-v423346/proxmark3"
#define LOCAL_PM3_SUBDIR "pm3/proxmark3"
#define DEFAULT_PORT "/dev/ttyACM0"

/* ------------------------------------------------------------------- state */

typedef enum { MODE_HF = 0, MODE_LF = 1, MODE_STATUS = 2 } scanmode_t;
typedef enum { ST_IDLE = 0, ST_SCANNING, ST_DONE } appstate_t;

typedef struct {
    char  lines[MAX_LOG][LINE_MAX];
    int   count;
} logbuf_t;

typedef struct {
    char  text[MAX_FIND][LINE_MAX];
    int   count;
} findings_t;

static struct {
    appstate_t   state;
    scanmode_t   mode;          /* selected / running mode */
    scanmode_t   last_mode;
    int          sel;           /* 0 = HF button, 1 = LF button */
    logbuf_t     log;
    findings_t   find;
    char         raw[RAW_CAP];
    size_t       raw_len;
    char         pending[LINE_MAX];
    size_t       pending_len;
    char         progress[LINE_MAX];
    char         status[LINE_MAX];
    int          scan_active;
    pid_t        pid;
    int          fd;
    Uint32       scan_start;
    Uint32       last_result;
    int          have_result;
    char         pm3bin[512];
    char         port[128];
    FILE        *logfile;
    int          run_seconds;
    int          want_scan;     /* from --auto-scan */
    const char  *shot_path;
    /* status widget (top-right) */
    char         bat_dir[256];
    int          bat_pct;        /* -1 = unknown */
    char         bat_status[24];
    char         clock_str[8];
    Uint32       ui_last;
} g;

/* ------------------------------------------------------------------- utils */

static void logf_(const char *fmt, ...) {
    char ts[32];
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    strftime(ts, sizeof ts, "%H:%M:%S", &tmv);

    va_list ap;
    va_start(ap, fmt);
    if (g.logfile) {
        fprintf(g.logfile, "[%s] ", ts);
        vfprintf(g.logfile, fmt, ap);
        fputc('\n', g.logfile);
        fflush(g.logfile);
    }
    va_end(ap);
}

static int file_exists(const char *p) {
    return p && *p && access(p, R_OK) == 0;
}

/* Directory of this executable, without trailing slash. */
static void app_dir(char *out, size_t n) {
    ssize_t r = readlink("/proc/self/exe", out, n - 1);
    if (r <= 0) { snprintf(out, n, "."); return; }
    out[r] = '\0';
    char *slash = strrchr(out, '/');
    if (slash) *slash = '\0';
}

/* ------------------------------------------------------------------- scan */

static const char *mode_name(scanmode_t m) {
    switch (m) {
        case MODE_HF:  return "HF 13.56MHz";
        case MODE_LF:  return "LF 125kHz";
        default:       return "PM3 status";
    }
}

static const char *mode_command(scanmode_t m) {
    switch (m) {
        case MODE_HF:  return "hf search";
        case MODE_LF:  return "lf search";
        default:       return "hw version";
    }
}

static void scan_stop(void) {
    if (g.fd >= 0) { close(g.fd); g.fd = -1; }
    if (g.pid > 0) {
        kill(g.pid, SIGTERM);
        int st;
        for (int i = 0; i < 20; i++) {
            if (waitpid(g.pid, &st, WNOHANG) == g.pid) break;
            usleep(20000);
        }
        kill(g.pid, SIGKILL);
        waitpid(g.pid, &st, WNOHANG);
        g.pid = -1;
    }
    g.scan_active = 0;
}

/* Split incoming bytes into lines and classify them. */
static void ingest_char(char c) {
    if (c != '\n' && c != '\r') {
        if (g.pending_len < LINE_MAX - 1) g.pending[g.pending_len++] = c;
        return;
    }
    g.pending[g.pending_len] = '\0';
    g.pending_len = 0;

    char *s = g.pending;
    while (*s == ' ' || *s == '\t') s++;

    /* Drop spinner-only fragments such as "[|]" or "[/]" */
    char compact[LINE_MAX];
    size_t k = 0;
    for (size_t i = 0; s[i] && k < sizeof compact - 1; i++) {
        char ch = s[i];
        if (ch == '[' || ch == ']' || ch == '|' || ch == '/' || ch == '\\' ||
            ch == '-' || ch == ' ' || ch == '\t')
            continue;
        compact[k++] = ch;
    }
    compact[k] = '\0';

    /* "[-] Searching for Topaz tag..." is progress, not a result: it belongs on
     * the progress line. Protocol names inside it would otherwise match the
     * findings keywords below and flood the pane. */
    if (strstr(s, "Searching for")) {
        snprintf(g.progress, sizeof g.progress, "%s", s);
        return;
    }
    if (compact[0] == '\0') return;

    if (g.log.count < MAX_LOG) {
        snprintf(g.log.lines[g.log.count], LINE_MAX, "%s", s);
        g.log.count++;
    } else {
        memmove(g.log.lines[0], g.log.lines[1], sizeof(g.log.lines[0]) * (MAX_LOG - 1));
        snprintf(g.log.lines[MAX_LOG - 1], LINE_MAX, "%s", s);
    }

    /* Lines worth surfacing large. Keep this permissive: a false positive in
     * the findings pane is harmless, a missed tag is not. */
    static const char *keys[] = {
        "UID", "CSN", "Valid ", "tag found", "tags found", "Card type", "Chipset",
        "Credential", "Magic", "ATQA", "SAK", "FC:", "CN:", "iCLASS",
        "PicoPass", "MIFARE", "ISO 14443", "ISO 15693", "FeliCa", "Topaz",
        "LEGIC", "EM 410x", "ID:", "Firmware", "Bootrom", "uC:",
        "flash memory", "Detected", "Key", "parity", "format", NULL
    };
    for (int i = 0; keys[i]; i++) {
        if (strstr(s, keys[i])) {
            if (g.find.count < MAX_FIND) {
                snprintf(g.find.text[g.find.count], LINE_MAX, "%s", s);
                g.find.count++;
            }
            g.last_result = SDL_GetTicks();
            g.have_result = 1;
            break;
        }
    }
}

/* "  Firmware.................. PM3 GENERIC" -> "PM3 GENERIC" */
static const char *after_dots(const char *line) {
    const char *p = line;
    while (*p && *p != '.') p++;
    if (!*p) return line;
    while (*p == '.' || *p == ' ') p++;
    return p;
}

/* Turn a finished "hw version" scan into a one-line header status. */
static void status_from_findings(int ok) {
    const char *model = NULL, *ver = NULL;
    for (int i = 0; i < g.find.count; i++) {
        const char *l = g.find.text[i];
        if (!model && strstr(l, "Firmware")) model = after_dots(l);
        if (!ver && strstr(l, "Bootrom")) {
            const char *v = strstr(l, "v4.");
            if (v) ver = v;
        }
    }
    char vbuf[80] = "";
    if (ver) {
        size_t n = strcspn(ver, " ");
        if (n >= sizeof vbuf) n = sizeof vbuf - 1;
        memcpy(vbuf, ver, n);
        vbuf[n] = '\0';
    }
    if (!model && !ver)
        snprintf(g.status, sizeof g.status, "Proxmark3 %s",
                 ok ? "detected" : "not responding");
    else
        snprintf(g.status, sizeof g.status, "%s%s%s",
                 model ? model : "Proxmark3",
                 vbuf[0] ? "  fw " : "", vbuf);

    g.find.count = 0;   /* device info is not a scan result */
    g.log.count = 0;
    logf_("pm3 status: %s", g.status);
}

static void scan_start(scanmode_t m) {
    scan_stop();

    g.mode = m;
    g.last_mode = m;
    g.find.count = 0;
    g.log.count = 0;
    g.raw_len = 0;
    g.pending_len = 0;
    g.progress[0] = '\0';
    g.raw[0] = '\0';
    g.scan_start = SDL_GetTicks();

    if (!file_exists(g.pm3bin)) {
        snprintf(g.status, sizeof g.status, "proxmark3 client not found: %s", g.pm3bin);
        logf_("start refused: %s", g.status);
        g.state = ST_DONE;
        return;
    }
    if (!file_exists(g.port)) {
        snprintf(g.status, sizeof g.status, "no Proxmark3 on %s", g.port);
        logf_("start refused: %s", g.status);
        g.state = ST_DONE;
        return;
    }

    int fds[2];
    if (pipe(fds) != 0) {
        snprintf(g.status, sizeof g.status, "pipe() failed: %s", strerror(errno));
        g.state = ST_DONE;
        return;
    }

    pid_t pid = fork();
    if (pid < 0) {
        close(fds[0]); close(fds[1]);
        snprintf(g.status, sizeof g.status, "fork() failed: %s", strerror(errno));
        g.state = ST_DONE;
        return;
    }

    if (pid == 0) {
        /* child: client output goes down the pipe; -f flushes every print
         * (stdout is a pipe here, so without it we would see nothing until exit) */
        dup2(fds[1], STDOUT_FILENO);
        dup2(fds[1], STDERR_FILENO);
        close(fds[0]);
        close(fds[1]);
        int devnull = open("/dev/null", O_RDONLY);
        if (devnull >= 0) dup2(devnull, STDIN_FILENO);
        execl(g.pm3bin, g.pm3bin, g.port, "--incognito", "-f",
              "-c", mode_command(m), (char *)NULL);
        _exit(127);
    }

    close(fds[1]);
    g.pid = pid;
    g.fd = fds[0];
    fcntl(g.fd, F_SETFL, O_NONBLOCK);
    g.scan_active = 1;
    g.state = ST_SCANNING;
    g.have_result = 0;
    snprintf(g.status, sizeof g.status, "scanning %s ...", mode_name(m));
    logf_("scan start: %s -> %s", mode_name(m), mode_command(m));
}

static void scan_poll(void) {
    if (!g.scan_active) return;

    char buf[4096];
    for (;;) {
        ssize_t n = read(g.fd, buf, sizeof buf);
        if (n > 0) {
            if (g.raw_len + (size_t)n < RAW_CAP) {
                memcpy(g.raw + g.raw_len, buf, (size_t)n);
                g.raw_len += (size_t)n;
                g.raw[g.raw_len] = '\0';
            }
            for (ssize_t i = 0; i < n; i++) ingest_char(buf[i]);
            continue;
        }
        break;
    }

    int st = 0;
    pid_t r = waitpid(g.pid, &st, WNOHANG);
    if (r == g.pid) {
        /* drain whatever is left, then finish */
        for (;;) {
            ssize_t n = read(g.fd, buf, sizeof buf);
            if (n <= 0) break;
            if (g.raw_len + (size_t)n < RAW_CAP) {
                memcpy(g.raw + g.raw_len, buf, (size_t)n);
                g.raw_len += (size_t)n;
                g.raw[g.raw_len] = '\0';
            }
            for (ssize_t i = 0; i < n; i++) ingest_char(buf[i]);
        }
        if (g.pending_len) { g.pending[g.pending_len] = '\n'; g.pending_len++; ingest_char('\n'); }

        close(g.fd); g.fd = -1; g.pid = -1;
        g.scan_active = 0;
        g.state = ST_DONE;
        g.progress[0] = '\0';

        int code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
        if (g.last_mode == MODE_STATUS) {
            status_from_findings(code == 0);
        } else if (g.find.count == 0)
            snprintf(g.status, sizeof g.status, "%s: no tag found (exit %d)",
                     mode_name(g.last_mode), code);
        else
            snprintf(g.status, sizeof g.status, "%s: %d finding(s)",
                     mode_name(g.last_mode), g.find.count);
        logf_("scan done: exit=%d findings=%d", code, g.find.count);
    }
}

/* ---------------------------------------------------------------- probe/CLI */

static void probe(void) {
    printf("SDL compiled : %d.%d.%d\n", SDL_MAJOR_VERSION, SDL_MINOR_VERSION, SDL_PATCHLEVEL);
    SDL_version lv;
    SDL_GetVersion(&lv);
    printf("SDL linked   : %d.%d.%d\n", lv.major, lv.minor, lv.patch);
    printf("video drivers: ");
    for (int i = 0; i < SDL_GetNumVideoDrivers(); i++) printf("%s ", SDL_GetVideoDriver(i));
    printf("\n");

    if (SDL_Init(SDL_INIT_VIDEO) != 0) {
        printf("SDL_Init(VIDEO) failed: %s\n", SDL_GetError());
        return;
    }
    printf("current video: %s\n", SDL_GetCurrentVideoDriver());
    int nd = SDL_GetNumVideoDisplays();
    printf("displays     : %d\n", nd);
    for (int i = 0; i < nd; i++) {
        SDL_DisplayMode dm;
        if (SDL_GetDesktopDisplayMode(i, &dm) == 0)
            printf("  display %d desktop: %dx%d @%dHz fmt=%s\n", i, dm.w, dm.h, dm.refresh_rate,
                   SDL_GetPixelFormatName(dm.format));
    }
    printf("joysticks    : %d\n", SDL_NumJoysticks());
    for (int i = 0; i < SDL_NumJoysticks(); i++)
        printf("  [%d] %s\n", i, SDL_JoystickNameForIndex(i));
    printf("ttf          : %s\n", TTF_Init() == 0 ? "ok" : TTF_GetError());
    if (TTF_WasInit()) TTF_Quit();
    SDL_Quit();
}

/* Run one scan to completion with no GUI, printing the raw client output. */
static int scan_once(scanmode_t m) {
    if (!file_exists(g.pm3bin)) { fprintf(stderr, "no client at %s\n", g.pm3bin); return 2; }
    printf("== %s: %s\n", mode_name(m), mode_command(m));
    fflush(stdout);

    int fds[2];
    if (pipe(fds) != 0) return 2;
    pid_t pid = fork();
    if (pid == 0) {
        dup2(fds[1], STDOUT_FILENO); dup2(fds[1], STDERR_FILENO);
        close(fds[0]); close(fds[1]);
        execl(g.pm3bin, g.pm3bin, g.port, "--incognito", "-f",
              "-c", mode_command(m), (char *)NULL);
        _exit(127);
    }
    close(fds[1]);
    char buf[4096];
    ssize_t n;
    while ((n = read(fds[0], buf, sizeof buf)) > 0)
        fwrite(buf, 1, (size_t)n, stdout);
    close(fds[0]);
    int st = 0; waitpid(pid, &st, 0);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 1;
}

/* ---------------------------------------------------------------- rendering */

static SDL_Color C( int r, int g_, int b) { SDL_Color c = { (Uint8)r, (Uint8)g_, (Uint8)b, 255 }; return c; }

static void fill(SDL_Renderer *r, SDL_Rect *rc, SDL_Color c) {
    SDL_SetRenderDrawColor(r, c.r, c.g, c.b, c.a);
    SDL_RenderFillRect(r, rc);
}

static void frame(SDL_Renderer *r, SDL_Rect *rc, SDL_Color c, int w) {
    SDL_SetRenderDrawColor(r, c.r, c.g, c.b, c.a);
    for (int i = 0; i < w; i++) {
        SDL_Rect t = { rc->x + i, rc->y + i, rc->w - 2 * i, rc->h - 2 * i };
        SDL_RenderDrawRect(r, &t);
    }
}

static int line_skip(TTF_Font *f, int fallback) {
    int v = f ? TTF_FontLineSkip(f) : 0;
    return v > 0 ? v : fallback;
}

/* ------------------------------------------------------- battery and clock */

static int read_int_file(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f) return -1;
    int v = -1;
    if (fscanf(f, "%d", &v) != 1) v = -1;
    fclose(f);
    return v;
}

/* Find the battery's sysfs directory. Prefers an entry whose name says
 * "battery"; falls back to the first power supply exposing `capacity`. */
static void battery_locate(void) {
    DIR *d = opendir("/sys/class/power_supply");
    if (!d) return;
    struct dirent *e;
    char best[256] = "";
    while ((e = readdir(d)) != NULL) {
        if (e->d_name[0] == '.') continue;
        char cap[320];
        snprintf(cap, sizeof cap, "/sys/class/power_supply/%s/capacity", e->d_name);
        if (!file_exists(cap)) continue;
        char dir[256];
        snprintf(dir, sizeof dir, "/sys/class/power_supply/%s", e->d_name);
        if (!best[0]) snprintf(best, sizeof best, "%s", dir);
        if (strstr(e->d_name, "battery")) { snprintf(best, sizeof best, "%s", dir); break; }
    }
    closedir(d);
    snprintf(g.bat_dir, sizeof g.bat_dir, "%s", best);
    logf_("battery: %s", best[0] ? best : "(none found)");
}

static void battery_read(void) {
    if (!g.bat_dir[0]) return;
    char p[320];
    snprintf(p, sizeof p, "%s/capacity", g.bat_dir);
    int v = read_int_file(p);
    if (v >= 0 && v <= 100) g.bat_pct = v;

    snprintf(p, sizeof p, "%s/status", g.bat_dir);
    FILE *f = fopen(p, "r");
    if (f) {
        if (fgets(g.bat_status, sizeof g.bat_status, f)) {
            char *nl = strchr(g.bat_status, '\n');
            if (nl) *nl = '\0';
        }
        fclose(f);
    }
}

/* Refresh battery + clock at most once a second. */
static void ui_tick(void) {
    Uint32 now = SDL_GetTicks();
    if (g.ui_last && now - g.ui_last < 1000) return;
    g.ui_last = now;
    battery_read();
    time_t t = time(NULL);
    struct tm tmv;
    localtime_r(&t, &tmv);
    strftime(g.clock_str, sizeof g.clock_str, "%H:%M", &tmv);
}

static void draw_line(SDL_Renderer *r, TTF_Font *f, const char *s, int x, int y, SDL_Color c) {
    SDL_Surface *sf = TTF_RenderUTF8_Blended(f, s, c);
    if (!sf) return;
    SDL_Texture *tx = SDL_CreateTextureFromSurface(r, sf);
    if (tx) {
        SDL_Rect d = { x, y, sf->w, sf->h };
        SDL_RenderCopy(r, tx, NULL, &d);
        SDL_DestroyTexture(tx);
    }
    SDL_FreeSurface(sf);
}

/* Draw text, wrapping at spaces to fit maxw. Returns the y below the block.
 * A string that already fits is drawn verbatim, so intentional runs of spaces
 * (the footer hints, the status line) survive. */
static int text(SDL_Renderer *r, TTF_Font *f, const char *s,
                int x, int y, SDL_Color c, int maxw) {
    if (!f || !s || !*s) return y;
    int line_h = line_skip(f, 18);

    if (!strchr(s, '\n')) {
        int tw = 0, th = 0;
        TTF_SizeUTF8(f, s, &tw, &th);
        if (tw <= maxw) { draw_line(r, f, s, x, y, c); return y + line_h; }
    }

    char line[LINE_MAX];
    line[0] = '\0';
    size_t k = 0;
    const char *p = s;

    while (*p) {
        if (*p == '\n') {
            if (k) { draw_line(r, f, line, x, y, c); y += line_h; k = 0; line[0] = '\0'; }
            p++;
            continue;
        }
        if (*p == ' ') { p++; continue; }

        const char *w = p;
        while (*w && *w != ' ' && *w != '\n') w++;
        size_t wl = (size_t)(w - p);

        char cand[LINE_MAX];
        if (k) snprintf(cand, sizeof cand, "%s %.*s", line, (int)wl, p);
        else   snprintf(cand, sizeof cand, "%.*s", (int)wl, p);

        int tw = 0, th = 0;
        TTF_SizeUTF8(f, cand, &tw, &th);
        if (tw > maxw && k) {
            draw_line(r, f, line, x, y, c);
            y += line_h;
            k = 0;
            line[0] = '\0';
            continue;               /* retry this word on a fresh line */
        }
        snprintf(line, sizeof line, "%s", cand);
        k = strlen(line);
        p = w;
    }
    if (k) { draw_line(r, f, line, x, y, c); y += line_h; }
    return y;
}

static const char *last_progress(void) {
    if (g.progress[0]) return g.progress;
    /* fall back to the tail of the raw stream */
    static char tail[128];
    size_t n = g.raw_len;
    size_t start = n > 100 ? n - 100 : 0;
    size_t k = 0;
    for (size_t i = start; i < n && k < sizeof tail - 1; i++) {
        char ch = g.raw[i];
        if (ch == '\n' || ch == '\r') { k = 0; continue; }
        tail[k++] = ch;
    }
    tail[k] = '\0';
    return tail;
}

/* Battery + clock, top-right of the header. */
static void draw_status_widget(SDL_Renderer *ren, TTF_Font *f_title, TTF_Font *f_body,
                               int W, int pad, SDL_Color text_c, SDL_Color dim,
                               SDL_Color ok) {
    if (!f_body) return;
    int title_h = f_title ? TTF_FontHeight(f_title) : 34;
    int th = TTF_FontHeight(f_body);
    int y = pad + (title_h - th) / 2;
    int x = W - pad;
    int tw = 0, hh = 0;

    /* clock, right-most */
    TTF_SizeUTF8(f_body, g.clock_str, &tw, &hh);
    x -= tw;
    draw_line(ren, f_body, g.clock_str, x, y, text_c);

    /* percentage */
    int charging = strstr(g.bat_status, "Charging") != NULL;
    char pct[16];
    if (g.bat_pct >= 0) snprintf(pct, sizeof pct, "%d%%", g.bat_pct);
    else                snprintf(pct, sizeof pct, "--%%");
    int pw = 0;
    TTF_SizeUTF8(f_body, pct, &pw, &hh);
    x -= pad + pw;
    draw_line(ren, f_body, pct, x, y, charging ? ok : text_c);

    /* battery icon */
    int bh = th - 4;
    if (bh < 10) bh = 10;
    int bw = bh * 2;
    x -= 10 + bw;
    SDL_Rect body = { x, y + (th - bh) / 2, bw, bh };
    frame(ren, &body, dim, 2);
    SDL_Rect nub = { body.x + bw + 1, body.y + bh / 4, 3, bh / 2 };
    fill(ren, &nub, dim);
    if (g.bat_pct >= 0) {
        int fw = (bw - 6) * g.bat_pct / 100;
        if (fw > 0) {
            SDL_Rect fl = { body.x + 3, body.y + 3, fw, bh - 6 };
            fill(ren, &fl, g.bat_pct <= 15 ? C(230, 80, 80)
                                           : (charging ? C(70, 200, 255) : ok));
        }
    }

    /* charging marker */
    if (charging) {
        int cw = 0;
        TTF_SizeUTF8(f_body, "CHG", &cw, &hh);
        x -= pad / 2 + cw;
        draw_line(ren, f_body, "CHG", x, y, ok);
    }
}

static void render(SDL_Renderer *ren, TTF_Font *f_title, TTF_Font *f_btn,
                   TTF_Font *f_body, TTF_Font *f_small, int W, int H) {
    SDL_Color bg     = C( 12,  16,  20);
    SDL_Color panel  = C( 26,  33,  42);
    SDL_Color text_c = C(232, 238, 244);
    SDL_Color dim    = C(138, 153, 168);
    SDL_Color hf_c   = C( 46, 158, 255);
    SDL_Color lf_c   = C(255, 140,  46);
    SDL_Color ok_c   = C( 76, 209, 100);

    SDL_SetRenderDrawColor(ren, bg.r, bg.g, bg.b, 255);
    SDL_RenderClear(ren);

    int pad = W / 40;
    int y   = pad;

    /* ---- header ---- */
    y = text(ren, f_title, "PM3 tools", pad, y, text_c, W - 2 * pad);
    char sub[LINE_MAX];
    snprintf(sub, sizeof sub, "%s  |  port %s", g.status[0] ? g.status : "ready", g.port);
    y = text(ren, f_small, sub, pad, y, dim, W - 2 * pad);
    y += pad / 2;

    draw_status_widget(ren, f_title, f_body, W, pad, text_c, dim, ok_c);

    /* ---- mode buttons ---- */
    int bw = (W - 3 * pad) / 2;
    int bh = H / 7;
    SDL_Rect bhf = { pad, y, bw, bh };
    SDL_Rect blf = { 2 * pad + bw, y, bw, bh };
    int sel_hf = (g.sel == 0);
    int scanning_hf = (g.state == ST_SCANNING && g.mode == MODE_HF);
    int scanning_lf = (g.state == ST_SCANNING && g.mode == MODE_LF);

    fill(ren, &bhf, sel_hf ? C(22, 48, 74) : panel);
    frame(ren, &bhf, scanning_hf ? ok_c : (sel_hf ? hf_c : dim), sel_hf ? 4 : 2);
    fill(ren, &blf, (!sel_hf) ? C(60, 38, 16) : panel);
    frame(ren, &blf, scanning_lf ? ok_c : (!sel_hf ? lf_c : dim), !sel_hf ? 4 : 2);

    text(ren, f_btn, "HF SCAN",  bhf.x + pad, bhf.y + bh / 10, sel_hf ? hf_c : text_c, bw - 2 * pad);
    text(ren, f_small, "13.56 MHz - ISO14443A/B, ISO15693, iCLASS, FeliCa",
         bhf.x + pad, bhf.y + bh / 2, dim, bw - 2 * pad);
    text(ren, f_btn, "LF SCAN",  blf.x + pad, blf.y + bh / 10, !sel_hf ? lf_c : text_c, bw - 2 * pad);
    text(ren, f_small, "125 kHz - EM410x, HID, Indala, T5577",
         blf.x + pad, blf.y + bh / 2, dim, bw - 2 * pad);

    y += bh + pad;

    /* ---- progress line while scanning ---- */
    if (g.state == ST_SCANNING) {
        char p[LINE_MAX];
        double secs = (SDL_GetTicks() - g.scan_start) / 1000.0;
        snprintf(p, sizeof p, "[%.0fs] %s", secs, last_progress());
        y = text(ren, f_body, p, pad, y, ok_c, W - 2 * pad);
    }
    y += pad / 2;

    /* ---- log pane geometry (bottom) ---- */
    int footer_h = H / 16;
    int log_h    = H / 4;
    int log_y    = H - footer_h - log_h - pad;

    /* ---- findings pane ---- */
    SDL_Rect fp = { pad, y, W - 2 * pad, log_y - y - pad };
    if (fp.h < 10) fp.h = 10;
    fill(ren, &fp, panel);
    frame(ren, &fp, dim, 1);

    int fy = fp.y + pad / 2;
    if (g.find.count == 0) {
        const char *msg = (g.state == ST_SCANNING)
            ? "Scanning... place the tag on the antenna"
            : "No findings yet - press A / Enter to scan";
        text(ren, f_body, msg, fp.x + pad / 2, fy, dim, fp.w - pad);
    } else {
        for (int i = 0; i < g.find.count && fy < fp.y + fp.h - 24; i++) {
            SDL_Color c = text_c;
            if (strstr(g.find.text[i], "UID") || strstr(g.find.text[i], "CSN") ||
                strstr(g.find.text[i], "Valid"))
                c = ok_c;
            fy = text(ren, f_body, g.find.text[i], fp.x + pad / 2, fy, c, fp.w - pad);
        }
    }

    /* ---- log pane ---- */
    SDL_Rect lp = { pad, log_y, W - 2 * pad, log_h };
    fill(ren, &lp, C(8, 11, 14));
    frame(ren, &lp, dim, 1);
    int lines_fit = (log_h - pad / 2) / line_skip(f_small, 16);
    int first = g.log.count - lines_fit;
    if (first < 0) first = 0;
    int ly = lp.y + pad / 4;
    for (int i = first; i < g.log.count; i++)
        ly = text(ren, f_small, g.log.lines[i], lp.x + pad / 2, ly, dim, lp.w - pad);

    /* ---- footer ---- */
    const char *hint = "A/Enter scan    B/Esc cancel+quit    L/R switch    F12 shot    R rescan";
    text(ren, f_small, hint, pad, H - footer_h + 2, dim, W - 2 * pad);
}

/* --------------------------------------------------------------------- main */

static void save_shot(SDL_Renderer *ren, int W, int H, const char *path) {
    SDL_Surface *s = SDL_CreateRGBSurfaceWithFormat(0, W, H, 32, SDL_PIXELFORMAT_ARGB8888);
    if (!s) { logf_("screenshot: CreateRGBSurface failed: %s", SDL_GetError()); return; }
    if (SDL_RenderReadPixels(ren, NULL, SDL_PIXELFORMAT_ARGB8888, s->pixels, s->pitch) != 0) {
        logf_("screenshot: RenderReadPixels failed: %s", SDL_GetError());
        SDL_FreeSurface(s);
        return;
    }
    if (SDL_SaveBMP(s, path) != 0) logf_("screenshot: SaveBMP failed: %s", SDL_GetError());
    else logf_("screenshot saved: %s", path);
    SDL_FreeSurface(s);
}

static void input_event(const SDL_Event *e) {
    if (e->type == SDL_KEYDOWN) {
        logf_("input: key %s (%d)", SDL_GetKeyName(e->key.keysym.sym), e->key.keysym.sym);
        switch (e->key.keysym.sym) {
            case SDLK_UP: case SDLK_LEFT:  g.sel = 0; break;
            case SDLK_DOWN: case SDLK_RIGHT: g.sel = 1; break;
            case SDLK_RETURN: case SDLK_KP_ENTER: case SDLK_SPACE:
            case SDLK_a: case SDLK_LCTRL:
                scan_start(g.sel == 0 ? MODE_HF : MODE_LF);
                break;
            case SDLK_ESCAPE: case SDLK_BACKSPACE: case SDLK_b:
                if (g.scan_active) {
                    scan_stop();
                    g.state = ST_DONE;
                    snprintf(g.status, sizeof g.status, "cancelled");
                } else {
                    SDL_Event q;
                    memset(&q, 0, sizeof q);
                    q.type = SDL_QUIT;
                    SDL_PushEvent(&q);
                }
                break;
            case SDLK_r: scan_start(g.last_mode); break;
            case SDLK_F12: g.shot_path = g.shot_path ? g.shot_path : "/tmp/pm3scan.bmp"; break;
            default: break;
        }
    } else if (e->type == SDL_JOYBUTTONDOWN) {
        /* Raw joystick indices, measured on the Brick Pro: A = 1, B = 0.
         * (These are raw indices, not SDL game-controller buttons, so the
         *  gamecontrollerdb mapping does not apply.) */
        logf_("input: joy button %d", e->jbutton.button);
        switch (e->jbutton.button) {
            case 1:     /* A -> scan the selected mode */
                scan_start(g.sel == 0 ? MODE_HF : MODE_LF);
                break;
            case 0:     /* B -> cancel a running scan, otherwise leave */
                if (g.scan_active) {
                    scan_stop();
                    g.state = ST_DONE;
                    snprintf(g.status, sizeof g.status, "cancelled");
                } else {
                    SDL_Event q;
                    memset(&q, 0, sizeof q);
                    q.type = SDL_QUIT;
                    SDL_PushEvent(&q);
                }
                break;
            case 2:     /* X -> rescan the last mode */
                scan_start(g.last_mode);
                break;
            case 3:     /* Y -> clear the panes */
                g.find.count = 0;
                g.log.count = 0;
                g.state = ST_IDLE;
                snprintf(g.status, sizeof g.status, "cleared");
                break;
        }
    } else if (e->type == SDL_JOYHATMOTION) {
        logf_("input: joy hat %d value %d", e->jhat.hat, e->jhat.value);
        if (e->jhat.value & SDL_HAT_UP)    g.sel = 0;
        if (e->jhat.value & SDL_HAT_DOWN)  g.sel = 1;
        if (e->jhat.value & SDL_HAT_LEFT)  g.sel = 0;
        if (e->jhat.value & SDL_HAT_RIGHT) g.sel = 1;
    }
}

int main(int argc, char **argv) {
    memset(&g, 0, sizeof g);
    g.fd = -1; g.pid = -1; g.state = ST_IDLE; g.sel = 0;
    g.mode = g.last_mode = MODE_HF;
    g.run_seconds = 0;
    g.want_scan = -1;   /* -1 = none; MODE_HF is 0, so 0 cannot mean "none" */

    char adir[512];
    app_dir(adir, sizeof adir);

    if (getenv("PM3_BIN")) {
        snprintf(g.pm3bin, sizeof g.pm3bin, "%s", getenv("PM3_BIN"));
    } else {
        char local[600];
        snprintf(local, sizeof local, "%s/%s", adir, LOCAL_PM3_SUBDIR);
        if (file_exists(local))
            snprintf(g.pm3bin, sizeof g.pm3bin, "%s", local);
        else
            snprintf(g.pm3bin, sizeof g.pm3bin, "%s", DEFAULT_PM3);
    }
    snprintf(g.port, sizeof g.port, "%s",
             getenv("PM3_PORT") ? getenv("PM3_PORT") : DEFAULT_PORT);
    char fontpath[600];
    snprintf(fontpath, sizeof fontpath, "%s/DejaVuSans.ttf", adir);

    int do_probe = 0, do_scan_once = -1;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--probe")) do_probe = 1;
        else if (!strcmp(argv[i], "--scan-once") && i + 1 < argc)
            do_scan_once = (!strcmp(argv[++i], "lf")) ? MODE_LF : MODE_HF;
        else if (!strcmp(argv[i], "--run-seconds") && i + 1 < argc)
            g.run_seconds = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--auto-scan") && i + 1 < argc) {
            g.want_scan = (!strcmp(argv[++i], "lf")) ? MODE_LF : MODE_HF;
            g.sel = (g.want_scan == MODE_LF) ? 1 : 0;
        }
        else if (!strcmp(argv[i], "--screenshot") && i + 1 < argc) g.shot_path = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc) snprintf(g.port, sizeof g.port, "%s", argv[++i]);
        else if (!strcmp(argv[i], "--pm3") && i + 1 < argc) snprintf(g.pm3bin, sizeof g.pm3bin, "%s", argv[++i]);
        else if (!strcmp(argv[i], "--log") && i + 1 < argc) g.logfile = fopen(argv[++i], "a");
        else if (!strcmp(argv[i], "--font") && i + 1 < argc) snprintf(fontpath, sizeof fontpath, "%s", argv[++i]);
        else if (!strcmp(argv[i], "--help") || !strcmp(argv[i], "-h")) {
            printf("pm3scan [--probe] [--scan-once hf|lf] [--auto-scan hf|lf]\n"
                   "        [--run-seconds N] [--screenshot FILE.bmp] [--log FILE]\n"
                   "        [--port DEV] [--pm3 PATH] [--font TTF]\n");
            return 0;
        }
    }

    if (!g.logfile) {
        char lp[600];
        snprintf(lp, sizeof lp, "%s/pm3scan.log", adir);
        g.logfile = fopen(lp, "a");
    }
    logf_("=== pm3scan start (pid %d) pm3=%s port=%s", (int)getpid(), g.pm3bin, g.port);

    battery_locate();

    if (do_probe) { probe(); return 0; }
    if (do_scan_once >= 0) return scan_once((scanmode_t)do_scan_once);

    if (SDL_Init(SDL_INIT_VIDEO | SDL_INIT_JOYSTICK) != 0) {
        logf_("SDL_Init failed: %s", SDL_GetError());
        fprintf(stderr, "SDL_Init failed: %s\n", SDL_GetError());
        return 1;
    }
    if (TTF_Init() != 0) {
        logf_("TTF_Init failed: %s", TTF_GetError());
        fprintf(stderr, "TTF_Init failed: %s\n", TTF_GetError());
        return 1;
    }

    SDL_DisplayMode dm;
    int W = 1024, H = 768;
    if (SDL_GetDesktopDisplayMode(0, &dm) == 0) { W = dm.w; H = dm.h; }
    logf_("display %dx%d driver=%s", W, H, SDL_GetCurrentVideoDriver());

    SDL_Window *win = SDL_CreateWindow("PM3 tools",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED, W, H,
        SDL_WINDOW_FULLSCREEN_DESKTOP | SDL_WINDOW_SHOWN);
    if (!win) {
        logf_("CreateWindow fullscreen failed (%s), retrying plain", SDL_GetError());
        win = SDL_CreateWindow("PM3 tools", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                               W, H, SDL_WINDOW_SHOWN);
    }
    if (!win) { logf_("CreateWindow failed: %s", SDL_GetError()); return 1; }

    SDL_Renderer *ren = SDL_CreateRenderer(win, -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!ren) ren = SDL_CreateRenderer(win, -1, SDL_RENDERER_SOFTWARE);
    if (!ren) { logf_("CreateRenderer failed: %s", SDL_GetError()); return 1; }
    SDL_RendererInfo ri;
    if (SDL_GetRendererInfo(ren, &ri) == 0) logf_("renderer: %s", ri.name);

    TTF_Font *f_title = TTF_OpenFont(fontpath, H / 22);
    TTF_Font *f_btn   = TTF_OpenFont(fontpath, H / 26);
    TTF_Font *f_body  = TTF_OpenFont(fontpath, H / 40);
    TTF_Font *f_small = TTF_OpenFont(fontpath, H / 56);
    if (!f_title || !f_btn || !f_body || !f_small)
        logf_("font load failed for %s: %s", fontpath, TTF_GetError());

    SDL_Joystick *joy = NULL;
    if (SDL_NumJoysticks() > 0) {
        joy = SDL_JoystickOpen(0);
        logf_("joystick: %s", joy ? SDL_JoystickName(joy) : "(open failed)");
        if (joy)
            logf_("joystick caps: buttons=%d hats=%d axes=%d",
                  SDL_JoystickNumButtons(joy), SDL_JoystickNumHats(joy),
                  SDL_JoystickNumAxes(joy));
    }
    for (int i = 0; i < SDL_NumJoysticks(); i++)
        logf_("joystick[%d]: %s", i, SDL_JoystickNameForIndex(i));

    /* keep the panel awake: same flag the stock apps use */
    FILE *sa = fopen("/tmp/stay_awake", "w");
    if (sa) { fputs("1\n", sa); fclose(sa); }

    if (g.want_scan >= 0) scan_start((scanmode_t)g.want_scan);
    else             scan_start(MODE_STATUS);   /* probe the PM3 on entry */

    Uint32 t0 = SDL_GetTicks();
    int running = 1;
    while (running) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) { running = 0; break; }
            input_event(&e);
        }
        scan_poll();
        ui_tick();

        render(ren, f_title, f_btn, f_body, f_small, W, H);
        SDL_RenderPresent(ren);

        if (g.run_seconds > 0 && (SDL_GetTicks() - t0) / 1000 >= (Uint32)g.run_seconds)
            running = 0;
        SDL_Delay(16);
    }

    if (g.shot_path) save_shot(ren, W, H, g.shot_path);
    scan_stop();
    unlink("/tmp/stay_awake");
    if (joy) SDL_JoystickClose(joy);
    if (f_title) TTF_CloseFont(f_title);
    if (f_btn)   TTF_CloseFont(f_btn);
    if (f_body)  TTF_CloseFont(f_body);
    if (f_small) TTF_CloseFont(f_small);
    TTF_Quit();
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    logf_("=== pm3scan exit");
    return 0;
}
