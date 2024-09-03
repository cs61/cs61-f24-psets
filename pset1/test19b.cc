#include "m61.hh"
#include <cstdio>
#include <cassert>
#include <cstring>
// m61_calloc with 0 count and/or size should be like m61_malloc(0).

int main() {
    void* p = m61_calloc(100, 0);
    m61_free(p);
    p = m61_calloc(0, 100);
    m61_free(p);
    p = m61_calloc(0, 0);
    m61_free(p);
    m61_print_statistics();
}

//! alloc count: active          0   total          3   fail          0
//! alloc size:  active          0   total          0   fail        ???
