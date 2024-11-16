#ifndef PONGBOARD_HH
#define PONGBOARD_HH
#include <cassert>
#include <vector>
#include <mutex>
#include <condition_variable>
#include <atomic>
#include "helpers.hh"
struct pong_ball;
struct pong_warp;
int random_int(int min, int max);


enum pong_celltype {
    cell_empty = 0,
    cell_sticky = 1,
    cell_warp = 2,
    cell_trash = 3,
    cell_obstacle = 4,
    cell_paddle = 5
};


struct pong_cell {
    pong_celltype type = cell_empty;  // type of cell

    // Non-obstacles only:
    pong_ball* ball = nullptr;        // pointer to ball currently in cell
                                      // (if any)

    // Obstacles only:
    int strength = 0;                 // obstacle strength

    // Warp cells only:
    pong_warp* warp = nullptr;        // pointer to warp (if any)

    void hit_obstacle();
};


struct pong_board {
    int width;
    int height;
    std::vector<pong_cell> cells;     // `width * height`, row-major order
    std::vector<pong_warp*> warps;

    pong_cell obstacle_cell;          // represents off-board positions
    unsigned long ncollisions = 0;


    pong_board(int w, int h);
    ~pong_board();

    // boards can't be copied, moved, or assigned
    pong_board(const pong_board&) = delete;
    pong_board& operator=(const pong_board&) = delete;


    // cell(x, y)
    //    Return a reference to the cell at position `x, y`. If there is
    //    no such position, returns `obstacle_cell`, a cell containing an
    //    obstacle.
    pong_cell& cell(int x, int y) {
        if (x < 0 || x >= this->width || y < 0 || y >= this->height) {
            return this->obstacle_cell;
        } else {
            return this->cells[y * this->width + x];
        }
    }
};



struct pong_ball {
    pong_board& board;
    bool stopped = false;
    int x = 0;
    int y = 0;
    int dx = 1;
    int dy = 1;


    // pong_ball(board)
    //    Construct a new ball on `board`.
    pong_ball(pong_board& board_)
        : board(board_) {
    }

    // balls can't be copied, moved, or assigned
    pong_ball(const pong_ball&) = delete;
    pong_ball& operator=(const pong_ball&) = delete;


    // move()
    //    Move this ball once on its board. Returns 1 if the ball moved to an
    //    empty cell, -1 if it fell off the board, and 0 otherwise.
    int move();
};


struct pong_warp {
    pong_board& board;
    int x;
    int y;
    pong_ball* ball = nullptr;


    pong_warp(pong_board& board_)
        : board(board_) {
    }

    // transfer a ball into this warp tunnel
    void accept_ball(pong_ball* b);
};

#endif
