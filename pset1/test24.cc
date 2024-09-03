#include "m61.hh"
#include <cstdio>
#include <cassert>
#include <vector>
#include <random>
// Check for memory reuse: up to 100 variable-sized active allocations.

int main() {
    std::default_random_engine randomness(std::random_device{}());

    const size_t nmax = 100;
    char* ptrs[nmax];
    size_t sizes[nmax];
    size_t n = 0;

    // 5000 times, allocate or free
    for (int i = 0; i != 10000; ++i) {
        if (uniform_int(size_t(0), nmax * nmax - 1, randomness) < n * n) {
            assert(n > 0);
            size_t j = uniform_int(size_t(0), n - 1, randomness);
            m61_free(ptrs[j]);
            --n;
            ptrs[j] = ptrs[n];
            sizes[j] = sizes[n];
        } else {
            assert(n < nmax);
            size_t size = uniform_int(1, 4000, randomness);
            char* ptr = (char*) m61_malloc(size);
            assert(ptr);
            for (size_t k = 0; k != n; ++k) {
                assert(ptrs[k] + sizes[k] <= ptr || ptr + size <= ptrs[k]);
            }
            ptrs[n] = ptr;
            sizes[n] = size;
            ++n;
        }
    }

    // clean up
    for (size_t j = 0; j != n; ++j) {
        m61_free(ptrs[j]);
    }

    m61_print_statistics();
}

//! alloc count: active          0   total        ???   fail          0
//! alloc size:  active        ???   total        ???   fail          0
