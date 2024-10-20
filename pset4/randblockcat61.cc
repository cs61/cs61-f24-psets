#include "io61.hh"
#include <cmath>

// Usage: ./randblockcat61 [-b MAXBLOCKSIZE] [-r RANDOMSEED] [FILE]
//    Copies the input FILE to standard output in blocks. Each block has a
//    random size between 1 and MAXBLOCKSIZE (which defaults to 4096).
//    One-byte blocks are read and written using io61_readc and io61_writec.

int main(int argc, char* argv[]) {
    // Parse arguments
    io61_args args = io61_args("b:r:o:i:XRW", 4096).set_seed(83419)
        .parse(argc, argv);

    // Allocate buffer, open files
    unsigned char* buf = new unsigned char[args.block_size];
    using distrib_type = std::uniform_int_distribution<size_t>;
    distrib_type szdistrib;
    if (args.exponential) {
        szdistrib = distrib_type(0, (size_t) ceil(log2(args.block_size)));
    } else {
        szdistrib = distrib_type(1, args.block_size);
    }

    io61_file* inf = io61_open_check(args.input_file, O_RDONLY);
    io61_file* outf = io61_open_check(args.output_file,
                                      O_WRONLY | O_CREAT | O_TRUNC);

    // Copy file data
    while (true) {
        size_t sz = szdistrib(args.engine);
        if (args.exponential) {
            sz = std::min(size_t(1) << sz, args.block_size);
        }

        ssize_t nr;
        if (sz == 1) {
            int ch = io61_readc(inf);
            buf[0] = ch;
            nr = ch >= 0 ? 1 : 0;
        } else if (args.read_bytes) {
            nr = io61_read_bytes(inf, buf, sz);
        } else {
            nr = io61_read(inf, buf, sz);
        }
        if (nr <= 0) {
            break;
        }

        ssize_t nw;
        if (sz == 1) {
            nw = io61_writec(outf, buf[0]) >= 0 ? 1 : 0;
        } else if (args.write_bytes) {
            nw = io61_write_bytes(outf, buf, nr);
        } else {
            nw = io61_write(outf, buf, nr);
        }
        assert(nw == nr);

        args.after_write(outf);
    }

    io61_close(inf);
    io61_close(outf);
    delete[] buf;
}
