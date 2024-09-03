#include "m61.hh"
#include <cstdio>
// Check that simultaneously-active allocations have different addresses.

int main() {
    void* ptrs[10];
    for (int i = 0; i != 10; ++i) {
        ptrs[i] = m61_malloc(1);
        for (int j = 0; j != i; ++j) {
            assert(ptrs[i] != ptrs[j]);
        }
    }
    m61_print_statistics();
}

//! alloc count: active        ???   total         10   fail        ???
//! alloc size:  active        ???   total        ???   fail        ???
