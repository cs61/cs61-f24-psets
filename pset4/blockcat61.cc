#include "io61.hh"

// Usage: ./blockcat61 [-b BLOCKSIZE] [-o OUTFILE] [FILE]
//    Copies the input FILE to standard output in blocks.
//    With `-R`, reads bytewise; with `-W`, writes bytewise.
//    Default BLOCKSIZE is 4096.

int main(int argc, char* argv[]) {
    // Parse arguments
    io61_args args = io61_args("b:o:i:D:FRWy", 4096).parse(argc, argv);

    // Allocate buffer, open files
    unsigned char* buf = new unsigned char[args.block_size];
    io61_file* inf = io61_open_check(args.input_file, O_RDONLY);
    io61_file* outf = io61_open_check(args.output_file,
                                      O_WRONLY | O_CREAT | O_TRUNC);
    args.after_open(inf, O_RDONLY);
    args.after_open(outf, O_WRONLY);

    // Copy file data
    while (true) {
        ssize_t nr;
        if (args.read_bytes) {
            nr = io61_read_bytes(inf, buf, args.block_size);
        } else {
            nr = io61_read(inf, buf, args.block_size);
        }
        if (nr <= 0) {
            break;
        }

        ssize_t nw;
        if (args.write_bytes) {
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
