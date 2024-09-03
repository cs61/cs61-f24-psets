#include "m61.hh"
#include <cstdio>
#include <cassert>
#include <cstring>
// Check that the most recent double-free isn’t mistaken for an invalid free.

int main() {
    void* ptr1 = m61_malloc(2001);
    void* ptr2 = m61_malloc(100);
    void* ptr3 = m61_malloc(2000);
    fprintf(stderr, "Will double free %p\n", (char*) ptr2);
    m61_free(ptr1);
    m61_free(ptr3);
    m61_free(ptr2); // may cause coalescing
    m61_free(ptr2);
    m61_print_statistics();
}

//! Will double free ??{0x\w+}=ptr??
//! MEMORY BUG: test???.cc:15: invalid free of pointer ??ptr??, double free
//! ???
//!!ABORT
