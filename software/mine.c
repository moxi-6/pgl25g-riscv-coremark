/* Mine Clear (扫雷) for the ATK-L50 RV32I board.
 *
 * 9x9 board drawn entirely by lcd_mine_display.sv from a packed tile bus
 * (4 bits per cell, 16 words at 0x1000_00A0).  Software only keeps the game
 * state and streams the tiles; all glyph work stays in hardware.
 *
 * Controls
 *   KEY0 / KEY1 : move cursor left / right
 *   KEY2        : move cursor down (wraps to the top of the column)
 *   KEY3 tap    : open the cell under the cursor
 *   KEY3 hold   : toggle a flag
 *   Touch tap   : jump the cursor to the tapped cell and open it
 *
 * Eight levels with changing terrain and mine counts. UART prints events so the
 * board can be driven head-less over the console.
 */

#include <stdint.h>

#define MMIO(a)  (*(volatile uint32_t *)(a))

#define LED      MMIO(0x10000000u)
#define UART     MMIO(0x10000004u)
#define KEY      MMIO(0x10000008u)
#define CYCLES   MMIO(0x10000010u)
#define INSTRET  MMIO(0x10000018u)
#define FRAME    MMIO(0x10000044u)
#define TP_X     MMIO(0x10000054u)
#define TP_Y     MMIO(0x10000058u)
#define TP_STAT  MMIO(0x1000005Cu)
#define TP_EVT   MMIO(0x10000060u)
#define TILES    ((volatile uint32_t *)0x100000A0u)
#define MINE_COMMIT MMIO(0x100000E0u)

#define N         9
#define NCELLS    (N * N)
#define MAX_LEVEL 8
#define HOLD_FRAMES 18

/* Tile codes understood by the renderer. */
#define T_COVER   0
#define T_BLANK   9
#define T_FLAG    10
#define T_MINE    11
#define T_BOOM    12
#define T_WRONG   13
#define T_WALL    14

static uint8_t mine[NCELLS];
static uint8_t open_cell[NCELLS];
static uint8_t flag[NCELLS];
static uint8_t adj[NCELLS];
static uint8_t pushed[NCELLS];
static uint8_t blocked[NCELLS];

static int cur_r, cur_c;
static int level;
static int mine_total;
static int opened_count;
static int flag_count;
static int placed;
static int game_over;
static int game_won;
static int boom_at;
static int active_count, flag_mode;
static uint32_t started_frame, elapsed_frames;

static uint32_t rng_state = 0x2545F491u;

static uint32_t rnd(void)
{
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 17;
    rng_state ^= rng_state << 5;
    return rng_state;
}

/* ---- tiny console ---------------------------------------------------- */

static void uart_putc(char c)
{
    while (UART & 0x80000000u) { }
    UART = (uint8_t)c;
}

static void uart_puts(const char *s)
{
    while (*s) uart_putc(*s++);
}

static void uart_dec(int v)
{
    char buf[12];
    int n = 0;
    if (v < 0) { uart_putc('-'); v = -v; }
    if (v == 0) { uart_putc('0'); return; }
    while (v > 0 && n < 11) { buf[n++] = (char)('0' + (v % 10)); v /= 10; }
    while (n--) uart_putc(buf[n]);
}

/* ---- board ----------------------------------------------------------- */

static void level_setup(int lv)
{
    int i;
    level = lv;
    mine_total = 8 + 2 * lv;
    if (mine_total > NCELLS - 12) mine_total = NCELLS - 12;
    placed = 0;
    game_over = 0;
    game_won = 0;
    boom_at = -1;
    opened_count = 0;
    flag_count = 0;
    active_count = 0;
    flag_mode = 0;
    elapsed_frames = 0;
    cur_r = 4;
    cur_c = 4;
    for (i = 0; i < NCELLS; i++) {
        mine[i] = 0;
        open_cell[i] = 0;
        flag[i] = 0;
        adj[i] = 0;
        pushed[i] = 0;
        {
            int r = i / N, c = i % N;
            int shape = (lv - 1) & 3;
            blocked[i] = (uint8_t)((shape == 1 && ((r < 2 || r > 6) && (c < 2 || c > 6))) ||
                (shape == 2 && c == 4 && (r == 1 || r == 2 || r == 6 || r == 7)) ||
                (shape == 3 && (r == 2 || r == 6) && (c == 1 || c == 2 || c == 6 || c == 7)));
            if (!blocked[i]) active_count++;
        }
    }
    uart_puts("== level ");
    uart_dec(lv);
    uart_puts(" mines ");
    uart_dec(mine_total);
    uart_puts("\n");
}

static void index_rc(int k, int *r, int *c)
{
    *r = k / N;
    *c = k % N;
}

static int neighbours(int r, int c, int out[8])
{
    int n = 0;
    int dr, dc;
    for (dr = -1; dr <= 1; dr++) {
        for (dc = -1; dc <= 1; dc++) {
            int rr, cc;
            if (dr == 0 && dc == 0) continue;
            rr = r + dr;
            cc = c + dc;
            if (rr < 0 || rr >= N || cc < 0 || cc >= N) continue;
            out[n++] = rr * N + cc;
        }
    }
    return n;
}

static void place_mines(int safe)
{
    int placed_n = 0;
    int guard = 0;
    int nb[8];
    int safe_r, safe_c, safe_n;
    int i;

    index_rc(safe, &safe_r, &safe_c);
    safe_n = neighbours(safe_r, safe_c, nb);

    /* The first click always opens a blank area: keep the 3x3 around it
     * clear of mines so the game starts with a real decision, not luck. */
    while (placed_n < mine_total && guard < 20000) {
        int k = (int)(rnd() % (uint32_t)NCELLS);
        int clear = 0;
        guard++;
        if (mine[k] || blocked[k]) continue;
        if (k == safe) clear = 1;
        for (i = 0; i < safe_n; i++) if (nb[i] == k) clear = 1;
        if (clear) continue;
        mine[k] = 1;
        placed_n++;
    }
    /* Deterministic fallback preserves the same first-click exclusion ring. */
    for (i = 0; i < NCELLS && placed_n < mine_total; i++) {
        int r = i / N, c = i % N;
        if (!mine[i] && !blocked[i] &&
            (r < safe_r - 1 || r > safe_r + 1 || c < safe_c - 1 || c > safe_c + 1)) {
            mine[i] = 1; placed_n++;
        }
    }

    for (i = 0; i < NCELLS; i++) {
        int r, c;
        int m = 0, j;
        index_rc(i, &r, &c);
        safe_n = neighbours(r, c, nb);
        for (j = 0; j < safe_n; j++) if (mine[nb[j]]) m++;
        adj[i] = (uint8_t)m;
    }
    placed = 1;
    started_frame = FRAME;
    uart_puts("mines placed\n");
}

static void open_flood(int start)
{
    int stack[NCELLS];
    int sp = 0, i;
    for (i = 0; i < NCELLS; i++) pushed[i] = 0;
    pushed[start] = 1;
    stack[sp++] = start;
    while (sp) {
        int k = stack[--sp];
        int r, c, nb[8], n, j;
        if (open_cell[k] || flag[k] || mine[k] || blocked[k]) continue;
        open_cell[k] = 1;
        opened_count++;
        if (adj[k] != 0) continue;
        index_rc(k, &r, &c);
        n = neighbours(r, c, nb);
        for (j = 0; j < n; j++) {
            if (!open_cell[nb[j]] && !flag[nb[j]] && !blocked[nb[j]] && !pushed[nb[j]]) {
                pushed[nb[j]] = 1;
                stack[sp++] = nb[j];
            }
        }
    }
}

static void check_win(void)
{
    if (!game_over && opened_count == active_count - mine_total) {
        game_won = 1;
        uart_puts("level clear!\n");
    }
}

static void do_open(int k)
{
    if (game_over || game_won) return;
    if (k < 0 || k >= NCELLS) return;
    if (open_cell[k] || flag[k] || blocked[k]) return;
    if (!placed) { rng_state ^= CYCLES; place_mines(k); }
    if (mine[k]) {
        game_over = 1;
        boom_at = k;
        uart_puts("boom\n");
        return;
    }
    open_flood(k);
    check_win();
}

static void do_flag(int k)
{
    if (game_over || game_won) return;
    if (k < 0 || k >= NCELLS || open_cell[k] || blocked[k]) return;
    if (flag[k]) {
        flag[k] = 0;
        flag_count--;
    } else {
        if (flag_count >= mine_total) return;
        flag[k] = 1;
        flag_count++;
    }
    uart_puts(flag[k] ? "flag " : "unflag ");
    uart_dec(k / N);
    uart_putc(',');
    uart_dec(k % N);
    uart_putc('\n');
}

/* ---- renderer feed --------------------------------------------------- */

static uint8_t tile_code(int k)
{
    if (blocked[k]) return T_WALL;
    if (game_won && mine[k]) return T_MINE;
    if (game_over && k == boom_at) return T_BOOM;
    if (game_over && mine[k]) return T_MINE;
    if (game_over && flag[k] && !mine[k]) return T_WRONG;
    if (open_cell[k]) {
        if (mine[k]) return T_MINE;
        return adj[k] ? (uint8_t)adj[k] : T_BLANK;
    }
    if (flag[k]) return T_FLAG;
    return T_COVER;
}

static void render(void)
{
    int w, b;
    /* The previous complete snapshot is consumed at the next video frame. */
    while (MINE_COMMIT & 1u) { }
    for (w = 0; w < 11; w++) {
        uint32_t word = 0;
        for (b = 0; b < 8; b++) {
            int k = w * 8 + b;
            if (k < NCELLS) word |= (uint32_t)tile_code(k) << (b * 4);
        }
        TILES[w] = word;
    }
    TILES[11] = (uint32_t)(cur_c & 15)
              | ((uint32_t)(cur_r & 15) << 4)
              | ((uint32_t)(game_won || game_over) << 8)
              | ((uint32_t)game_won << 9);
    TILES[12] = (uint32_t)level | ((uint32_t)mine_total << 8) |
                ((uint32_t)flag_count << 16) | ((uint32_t)(active_count-mine_total-opened_count) << 24);
    TILES[13] = elapsed_frames / 45u;
    TILES[14] = (uint32_t)((level - 1) & 3) | ((uint32_t)flag_mode << 8) |
                ((uint32_t)placed << 9) | ((uint32_t)game_over << 10) | ((uint32_t)game_won << 11);
    TILES[15] = (uint32_t)opened_count | ((uint32_t)active_count << 8) | (MAX_LEVEL << 16);
    MINE_COMMIT = 1u;
    /* Remaining safe cells on the LEDs, inverted so a dim board means done. */
    LED = (uint32_t)(~(unsigned)(active_count - mine_total - opened_count)) & 0xFFu;
}

/* ---- input ----------------------------------------------------------- */

static int touch_to_cell(uint32_t tx, uint32_t ty)
{
    int c, r;
    if (tx < 104u || tx >= 536u) return -1;
    if (ty < 24u || ty >= 456u) return -1;
    c = (int)((tx - 104u) / 48u);
    r = (int)((ty - 24u) / 48u);
    if (c < 0 || c >= N || r < 0 || r >= N) return -1;
    return r * N + c;
}

int main(void)
{
    uint32_t last_frame = FRAME, prev_keys = 0, key3_down_at = 0;
    int key3_held = 0, wait_release = 0;
    uart_puts("\n=== FPGA minesweeper / 8 stages ===\n");
    uart_puts("KEY0 left KEY1 right KEY2 down KEY3 tap=open hold=flag\n");
    uart_puts("Touch board to open; right button switches flag mode.\n");
    level_setup(1);
    render();
    for (;;) {
        uint32_t now = FRAME, keys, pressed, st;
        int k;
        if (now == last_frame) continue;
        last_frame = now;
        keys = (~KEY) & 0xFu;
        pressed = keys & ~prev_keys;
        st = TP_STAT;
        if (placed && !game_over && !game_won) elapsed_frames = now - started_frame;
        if (wait_release) {
            if (st & 2u) TP_STAT = 0u;
            if (!keys && !(st & 1u)) wait_release = 0;
            prev_keys = keys;
            render();
            continue;
        }
        /* A finished board stays visible until an explicit new action. */
        if (game_over || game_won) {
            if (pressed || ((st & 2u) && TP_X >= 648u && TP_Y >= 416u && TP_Y < 456u)) {
                int next = game_won ? (level < MAX_LEVEL ? level + 1 : 1) : level;
                TP_STAT = 0u;
                level_setup(next);
                key3_held = 0;
                wait_release = 1;
            } else if (st & 2u) TP_STAT = 0u;
            prev_keys = keys;
            render();
            continue;
        }
        if (pressed & 1u) cur_c = cur_c > 0 ? cur_c - 1 : N - 1;
        if (pressed & 2u) cur_c = cur_c < N - 1 ? cur_c + 1 : 0;
        if (pressed & 4u) cur_r = cur_r < N - 1 ? cur_r + 1 : 0;
        if (pressed & 8u) { key3_down_at = now; key3_held = 1; }
        if (key3_held && !(keys & 8u)) {
            key3_held = 0;
            k = cur_r * N + cur_c;
            if (now - key3_down_at < HOLD_FRAMES) do_open(k);
            else do_flag(k);
        }
        if (st & 2u) {
            uint32_t tx = TP_X, ty = TP_Y;
            TP_STAT = 0u;
            if (tx >= 648u && tx < 792u && ty >= 360u && ty < 400u) {
                flag_mode = !flag_mode;
            } else if (tx >= 648u && tx < 792u && ty >= 416u && ty < 456u) {
                level_setup(level);
                key3_held = 0;
                wait_release = 1;
            } else if (((st >> 5) & 15u) == 1u) {
                k = touch_to_cell(tx, ty);
                if (k >= 0 && !blocked[k]) {
                    cur_r = k / N;
                    cur_c = k % N;
                    if (flag_mode) do_flag(k); else do_open(k);
                }
            }
        }
        render();
        prev_keys = keys;
    }
}
