#include "board.hh"
#include "helpers.hh"
#include <unistd.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <cstdlib>
#include <cstring>
#include <cstdio>
#include <cerrno>
#include <cassert>
#include <atomic>
#include <thread>
#include <random>
#include <deque>
#include <functional>


// breakout board
pong_board* main_board;

// delay between moves, in microseconds
static unsigned long delay = 50'000;
// warp delay, in microseconds
static unsigned long warp_delay = 200'000;

// number of running threads
static std::atomic<long> nrunning = 0;


// THREADS

// ball_thread(b)
//    Move a ball until it falls off the board. Then destroy the
//    ball and exit.

void ball_thread(pong_ball* b) {
    ++nrunning;

    while (true) {
        int mval = b->move();
        if (mval > 0) {
            // ball successfully moved; wait `delay` to move it again
            if (delay > 0) {
                usleep(delay);
            }
        } else if (mval < 0) {
            // ball destroyed
            break;
        }
    }

    delete b;
    --nrunning;
}


// warp_thread(w)
//    Handle a warp tunnel. Must behave as follows:
//
//    1. Wait for a ball to enter this tunnel
//       (see `warp_thread::accept_ball()`).
//    2. Hide the ball for `warp_delay` microseconds.
//    3. Reveal the ball at position `warp->x,warp->y` (once that
//       position is available) and send it on its way.
//    4. Return to step 1.
//
//    The handout code is not thread-safe. Remove the `usleep(0)` functions
//    and it doesn’t work at all!

void warp_thread(pong_warp* w) {
    pong_cell& cdest = w->board.cell(w->x, w->y);
    while (true) {
        // wait for a ball to arrive
        while (!w->ball) {
            usleep(0);
        }

        // claim ball (move ball to warp tunnel)
        pong_ball* b = w->ball;
        w->ball = nullptr;

        // ball stays in warp tunnel for `warp_delay` usec
        usleep(warp_delay);

        // then it appears on the destination cell
        assert(!cdest.ball);
        cdest.ball = b;
        b->x = w->x;
        b->y = w->y;
        b->stopped = false;
    }
}


// paddle_thread(board, x, y, width)
//    Thread to move the paddle, which starts at position (`px`, `py`) and has
//    width `pw`.
//
//    Your code here! Our handout code just moves the paddle back & forth.

void paddle_thread(pong_board* b, int px, int py, int pw) {
    int dx = 1;
    while (true) {
        if (px + dx >= 0 && px + dx + pw <= b->width) {
            px += dx;
        } else {
            // hit edge of screen; reverse
            dx = -dx;
        }

        // represent paddle position as cell_paddle vs. cell_empty
        for (int x = 0; x < b->width; ++x) {
            if (x >= px && x < px + pw) {
                b->cell(x, py).type = cell_paddle;
            } else {
                b->cell(x, py).type = cell_empty;
            }
        }

        usleep(delay / 2);
    }
}


// MAIN

static void print_thread(pong_board*, long print_interval);

// usage()
//    Explain how breakout61 should be run.
static void usage() {
    fprintf(stderr, "\
Usage: ./breakout61 [-P] [-1] [-w WIDTH] [-h HEIGHT] [-b NBALLS] [-s NSTICKY]\n\
                    [-W NWARP] [-B NBRICKS] [-d MOVEPAUSE] [-p PRINTTIMER]\n");
    exit(1);
}

int main(int argc, char** argv) {
    // parse arguments and check size invariants
    int width = 100, height = 31, nballs = 24, nsticky = 12,
        nwarps = 0, nbricks = -1;
    long print_interval = 50'000;
    bool single_threaded = false, paddle = false, has_size = false;
    int ch;
    while ((ch = getopt(argc, argv, "w:h:b:B:s:d:p:W:j:1P")) != -1) {
        if (ch == 'w' && is_integer_string(optarg)) {
            width = strtol(optarg, nullptr, 10);
            has_size = true;
        } else if (ch == 'h' && is_integer_string(optarg)) {
            height = strtol(optarg, nullptr, 10);
            has_size = true;
        } else if (ch == 'b' && is_integer_string(optarg)) {
            nballs = strtol(optarg, nullptr, 10);
        } else if (ch == 's' && is_integer_string(optarg)) {
            nsticky = strtol(optarg, nullptr, 10);
        } else if (ch == 'W' && is_integer_string(optarg)) {
            nwarps = strtol(optarg, nullptr, 10);
        } else if (ch == 'B' && is_integer_string(optarg)) {
            nbricks = strtol(optarg, nullptr, 10);
        } else if (ch == 'd' && is_real_string(optarg)) {
            delay = (unsigned long) (strtod(optarg, nullptr) * 1000000);
        } else if (ch == 'p' && is_real_string(optarg)) {
            print_interval = (long) (strtod(optarg, nullptr) * 1000000);
        } else if (ch == 'P') {
            paddle = true;
        } else if (ch == '1') {
            single_threaded = true;
        } else {
            usage();
        }
    }
#ifdef TIOCGWINSZ
    if (!has_size && print_interval > 0) {
        // limit to size of terminal
        struct winsize ws;
        if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0) {
            width = std::max(std::min(width, (int) ws.ws_col - 1), 64);
            height = std::max(std::min(height, (int) ws.ws_row - 4), 12);
        }
    }
#endif
    if (nbricks < 0) {
        nbricks = height / 3;
    }
    if (optind != argc
        || width < 2
        || height < 2
        || nballs + nsticky + nwarps + width * nbricks >= width * (height - 2)
        || width > 1024
        || nwarps % 2 != 0
        || nballs == 0) {
        usage();
    }

    // create pong board
    pong_board board(width, height);
    main_board = &board;

    // place bricks
    for (int n = 0; n < nbricks; ++n) {
        for (int x = 0; x < width; ++x) {
            board.cell(x, n).type = cell_obstacle;
            board.cell(x, n).strength = (nbricks - n - 1) / 2 + 1;
        }
    }

    // place paddle
    if (paddle) {
        for (int x = 0; x < width; ++x) {
            board.cell(x, height - 1).type = cell_trash;
        }
        for (int x = 0; x < 8 && x < width; ++x) {
            board.cell(x, height - 2).type = cell_paddle;
        }
    }

    // place sticky locations
    for (int n = 0; n < nsticky; ++n) {
        int x, y;
        do {
            x = random_int(0, width - 1);
            y = random_int(0, height - 3);
        } while (board.cell(x, y).type != cell_empty);
        board.cell(x, y).type = cell_sticky;
    }

    // place warp pairs
    for (int n = 0; n < nwarps; n += 2) {
        pong_warp* w1 = new pong_warp(board);
        pong_warp* w2 = new pong_warp(board);

        do {
            w1->x = random_int(0, width - 1);
            w1->y = random_int(0, height - 3);
        } while (board.cell(w1->x, w1->y).type != cell_empty);
        board.cell(w1->x, w1->y).type = cell_warp;

        do {
            w2->x = random_int(0, width - 1);
            w2->y = random_int(0, height - 3);
        } while (board.cell(w2->x, w2->y).type != cell_empty);
        board.cell(w2->x, w2->y).type = cell_warp;

        // Each warp cell contains a pointer to the other end of the warp.
        board.cell(w1->x, w1->y).warp = w2;
        board.cell(w2->x, w2->y).warp = w1;

        board.warps.push_back(w1);
        board.warps.push_back(w2);
    }

    // place balls
    std::vector<pong_ball*> balls;
    for (int n = 0; n < nballs; ++n) {
        pong_ball* b = new pong_ball(board);
        do {
            b->x = random_int(0, width - 1);
            b->y = random_int(0, height - 3);
        } while (board.cell(b->x, b->y).type > cell_sticky
                 || board.cell(b->x, b->y).ball);
        b->dx = random_int(0, 1) ? 1 : -1;
        b->dy = random_int(0, 1) ? 1 : -1;
        board.cell(b->x, b->y).ball = b;
        balls.push_back(b);
    }

    // create print thread
    if (print_interval) {
        std::thread t(print_thread, main_board, print_interval);
        t.detach();
    }

    // single-threaded mode: one thread runs all balls
    if (single_threaded) {
        assert(nwarps == 0);
        while (true) {
            for (auto b : balls) {
                b->move();
            }
            if (delay) {
                usleep(delay);
            }
        }
    }

    // otherwise, multithreaded mode
    // create ball threads
    for (auto b : balls) {
        std::thread t(ball_thread, b);
        t.detach();
    }

    // create warp threads
    for (auto w : board.warps) {
        std::thread t(warp_thread, w);
        t.detach();
    }

    // create paddle thread
    if (paddle) {
        std::thread t(paddle_thread, main_board, 0, height - 2,
                      std::min(8, width));
        t.detach();
    }

    // main thread blocks forever
    while (true) {
        select(0, nullptr, nullptr, nullptr, nullptr);
    }
}


// BOARD PRINTING THREAD

// extract_board
//    Renders the board into an array of characters `buf`, and stores the
//    number of collisions in `ncollisions`. This is in a separate function
//    so we can localize unsafe access to `pong_board`.
//
//    NOTE: This function accesses the board in a thread-unsafe way. There is no
//    easy way to fix this and you aren't expected to fix it.
__attribute__((no_sanitize("thread")))
void extract_board(pong_board& board, unsigned char* buf,
                   unsigned long& ncollisions) {
    ncollisions = board.ncollisions;
    for (int y = 0; y < board.height; ++y) {
        for (int x = 0; x < board.width; ++x) {
            pong_cell& c = board.cell(x, y);
            if (auto b = c.ball) {
                int color = (reinterpret_cast<uintptr_t>(b) / 131) % 6;
                *buf = (c.type == cell_sticky ? 'g' : 'a') + color;
            } else if (c.type == cell_empty) {
                *buf = '.';
            } else if (c.type == cell_sticky) {
                *buf = '_';
            } else if (c.type == cell_obstacle) {
                *buf = 128 + std::min(c.strength, 16);
            } else if (c.type == cell_paddle) {
                *buf = '=';
            } else if (c.type == cell_warp) {
                *buf = 'W';
            } else if (c.type == cell_trash) {
                *buf = 'X';
            } else {
                *buf = '?';
            }
            ++buf;
        }
    }
}

// print_thread
//    Prints out the current state of the `board` to standard output every
//    `print_interval` microseconds.
void print_thread(pong_board* board, long print_interval) {
    static const unsigned char obstacle_colors[16] = {
        227, 46, 214, 160, 100, 101, 136, 137,
        138, 173, 174, 175, 210, 211, 212, 213
    };

    int width = main_board->width, height = main_board->height;
    unsigned char* mb[2] = {
        new unsigned char[width * height],
        new unsigned char[width * height]
    };
    int mbi = 0;
    memset(mb[1], 0, width * height);

    char buf[8192];
    simple_printer sp(buf, sizeof(buf));

    bool is_tty = isatty(STDOUT_FILENO);
    if (is_tty) {
        // clear screen
        sp << "\x1B[H\x1B[J" << spflush(STDOUT_FILENO);
    }

    while (true) {
        // extract board into `mb[mbi]`
        unsigned long ncollisions;
        extract_board(*board, mb[mbi], ncollisions);

        // print header
        if (is_tty) {
            sp << "\x1B[H\x1B[K";
        }
        sp << nrunning << " balls, " << ncollisions << " collisions";
        if (is_tty) {
            sp << " \x1B[1;30m(Ctrl-C to quit)\x1B[m";
        }
        sp << '\n' << spflush(STDOUT_FILENO);

        // print board
        unsigned char* mbp = mb[mbi];
        unsigned char* mbprev = mb[1 - mbi];
        int lasty = 0;
        for (int y = 0; y < height; ++y, mbprev += width) {
            // don't reprint a TTY line if unchanged from last time
            if (is_tty && memcmp(mbp, mbprev, width) == 0) {
                mbp += width;
                continue;
            }
            if (is_tty && lasty != y) {
                sp << "\x1B[" << long(2 + y) << "H";
            }
            for (int x = 0; x < width; ++x, ++mbp) {
                if (*mbp >= 'a' && *mbp <= 'l') {
                    if (is_tty && *mbp >= 'g') {
                        sp.snprintf("\x1B[%dmO\x1B[m", 31 + *mbp - 'g');
                    } else if (is_tty) {
                        sp.snprintf("\x1B[1;%dmO\x1B[m", 31 + *mbp - 'a');
                    } else {
                        sp << 'O';
                    }
                } else if (*mbp == '_' && is_tty) {
                    sp << "\x1B[37m_\x1B[m";
                } else if (*mbp == 'W' && is_tty) {
                    sp << "\x1B[97;45mW\x1B[m";
                } else if (*mbp == 'X' && is_tty) {
                    sp << "\x1B[32;40mX\x1B[m";
                } else if (*mbp == '=' && is_tty) {
                    sp << "\x1B[97;104m=\x1B[m";
                } else if (*mbp == 128) {
                    sp << (is_tty ? "\x1B[48;5;%dmX\x1B[m" : "X");
                } else if (*mbp > 128) {
                    char ch = (char) (*mbp > 137 ? '%' : '0' + *mbp - 128);
                    if (is_tty) {
                        sp.snprintf("\x1B[48;5;%dm%c\x1B[m",
                            obstacle_colors[std::min(*mbp - 128, 16) - 1],
                            ch);
                    } else {
                        sp << ch;
                    }
                } else {
                    sp << (char) *mbp;
                }
            }
            if (is_tty) {
                sp << "\x1B[K";
            }
            sp << '\n' << spflush(STDOUT_FILENO);
            lasty = y + 1;
        }
        if (is_tty && lasty != height) {
            sp << "\x1B[" << long(2 + height) << "H";
        }

        // print footer (blank line)
        sp << '\n' << spflush(STDOUT_FILENO);

        // wait for `print_interval`, then flip board buffer of interest
        usleep(print_interval);
        mbi = 1 - mbi;
    }

    delete[] mb[0];
    delete[] mb[1];
}
