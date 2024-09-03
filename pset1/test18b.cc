#include "m61.hh"
#include <cstdio>
#include <cassert>
// Check diabolical failed allocation.

int main() {
    void* ptrs[10];
    for (int i = 0; i != 10; ++i) {
        ptrs[i] = m61_malloc(i + 1);
    }
    for (int i = 0; i != 5; ++i) {
        m61_free(ptrs[i]);
    }
    for (size_t delta = 1; delta != 9; ++delta) {
        size_t very_large_size = SIZE_MAX - delta;
        void* garbage = m61_malloc(very_large_size);
        assert(garbage == nullptr);
    }
    m61_print_statistics();
}

//! alloc count: active          5   total         10   fail          8
//! alloc size:  active        ???   total         55   fail        ???
