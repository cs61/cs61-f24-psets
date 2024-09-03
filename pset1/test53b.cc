#include "m61.hh"
#include <cstdio>
#include <cassert>
#include <cstring>
// Check that an invalid free isn’t mistaken for a double free.

int main() {
    void* ptr1 = m61_malloc(2001);
    fprintf(stderr, "Will free %p\n", (char*) ptr1 + 150);
    m61_free(ptr1);
    m61_free((char*) ptr1 + 150);
    m61_print_statistics();
}

//! Will free ??{0x\w+}=ptr??
//! MEMORY BUG: test???.cc:11: invalid free of pointer ??ptr??, not allocated
//! ???
//!!ABORT
