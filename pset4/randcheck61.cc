#include "io61.hh"
#include <cmath>

// Usage: ./randcheck61 [-s SIZE] [-q INITSIZE] [FILE]
//    Checks `FILE` for randomness, using the test in Maurer (1992),
//    “A Universal Statistical Test for Random Bit Generators”

int main(int argc, char* argv[]) {
    // Parse arguments
    std::vector<const char*> input_files;
    size_t file_size = SIZE_MAX;
    size_t init_size = 4096;

    int arg;
    char* endptr;
    while ((arg = getopt(argc, argv, "i:s:q:")) != -1) {
        switch (arg) {
        case 's':
            file_size = (size_t) strtoul(optarg, &endptr, 0);
            if (endptr == optarg || *endptr) {
                goto usage;
            }
            break;
        case 'q':
            init_size = (size_t) strtoul(optarg, &endptr, 0);
            if (init_size == 0 || endptr == optarg || *endptr) {
                goto usage;
            }
            break;
        case 'i':
            input_files.push_back(optarg);
            break;
        default:
        usage:
            fprintf(stderr, "Usage: %s [OPTIONS] [FILE]\nOptions:\n", argv[0]);
            fprintf(stderr, "    -i FILE       Read input from FILE\n");
            fprintf(stderr, "    -s SIZE       Set size read\n");
            fprintf(stderr, "    -q SIZE       Set test initialization size\n");
            exit(1);
        }
    }
    for (int i = optind; i < argc; ++i) {
        input_files.push_back(argv[i]);
    }
    if (input_files.empty()) {
        input_files.push_back("-");
    }
    if (input_files.size() != 1) {
        goto usage;
    }

    // Open files
    const char* input_file = input_files[0];
    if (strcmp(input_file, "-") == 0) {
        input_file = nullptr;
    }
    FILE* f = stdio_open_check(input_file, O_RDONLY);
    const char* input_name = input_file ? input_file : "<stdin>";

    // Initialize table
    size_t table[256];
    for (int i = 0; i != 256; ++i) {
        table[i] = 0;
    }

    // Process data
    size_t pos = 0;
    int ch;
    long double sum = 0.0;
    while (pos < file_size && (ch = fgetc(f)) != EOF) {
        if (pos >= init_size) {
            sum += logl(pos - table[ch]);
        }
        table[ch] = pos;
        ++pos;
    }

    size_t K = pos - init_size;
    if (K < 256 * 1024) {
        // Not enough data for a reasonable test
        printf("%s: Not enough data to test randomness\n", input_name);
        exit(2);
    }
    long double fval = (sum / K) / logl(2.0);

    // Test result
    long double c = 0.6 + 0.53333333333333333 * powl(K, -0.375);
    long double sigma = c * sqrtl(3.238 / K);
    long double expected = 7.1836656;
    long double t1 = expected - 3.30 * sigma;
    long double t2 = expected + 3.30 * sigma;
    if (fval < t1) {
        printf("%s: Test parameter %Lg too low\n", input_name, fval);
        exit(1);
    } else if (fval > t2) {
        printf("%s: Test parameter %Lg too high\n", input_name, fval);
        exit(1);
    } else {
        exit(0);
    }
}
