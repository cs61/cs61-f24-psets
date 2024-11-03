#ifndef SH61_HH
#define SH61_HH
#include <cstdio>
#include <cstdlib>
#include <cassert>
#include <csignal>
#include <string>
#include <fcntl.h>
#include <unistd.h>

#define TYPE_NORMAL        0   // normal command word
#define TYPE_REDIRECT_OP   1   // redirection operator (>, <, 2>)

// All other tokens are control operators that terminate the current command.
#define TYPE_SEQUENCE      2   // `;` sequence operator or end of command line
#define TYPE_BACKGROUND    3   // `&` background operator
#define TYPE_PIPE          4   // `|` pipe operator
#define TYPE_AND           5   // `&&` operator
#define TYPE_OR            6   // `||` operator

// If you want to handle an extended shell syntax for extra credit, here are
// some other token types to get you started.
#define TYPE_LPAREN        7   // `(` operator
#define TYPE_RPAREN        8   // `)` operator
#define TYPE_OTHER         -1

struct shell_tokenizer;


// shell_parser
//    A `shell_parser` object navigates a command line according to the
//    shell grammar. Each `shell_parser` examines a region (substring) of
//    a command line. Functions like `next*` advance a parser to the next
//    region of a given type (conditional, pipeline, or command), while
//    functions like `first*` return *sub-parsers* of a given type that
//    navigate *within* the current region.

struct shell_parser {
    explicit shell_parser(const char* str);
    shell_parser(const char* first, const char* last);

    // Test if the current region is empty
    inline constexpr explicit operator bool() const;
    inline constexpr bool empty() const;

    // Return the contents of the region as a string, for debugging
    inline std::string str() const;

    // Return the operator token type immediately following the current region
    int op() const;
    const char* op_name() const;

    // Navigate by conditionals within a list
    shell_parser first_conditional() const;
    void next_conditional();

    // Navigate by pipelines within a conditional
    shell_parser first_pipeline() const;
    void next_pipeline();

    // Navigate by commands within a pipeline
    shell_parser first_command() const;
    void next_command();

    // Return `shell_tokenizer` that navigates by tokens within a command
    shell_tokenizer first_token() const;

private:
    const char* _s;
    const char* _stop;
    const char* _end;

    shell_parser first_delimited(unsigned long fl) const;
    void next_delimited(unsigned long fl);
    shell_parser(const char* first, const char* stop, const char* last);
};


// shell_tokenizer
//    A `shell_tokenizer` object breaks down a command line into tokens.

struct shell_tokenizer {
    explicit shell_tokenizer(const char* str);
    shell_tokenizer(const char* first, const char* last);

    // Test if there are more tokens
    inline constexpr explicit operator bool() const;
    inline constexpr bool empty() const;

    // Return the current token’s contents as a string
    std::string str() const;

    // Return the current token’s type
    inline constexpr int type() const;
    const char* type_name() const;

    // Advance to the next token, if any
    void next();

private:
    const char* _s;
    const char* _end;
    short _type;
    bool _quoted;
    unsigned _len;

    friend struct shell_parser;
};


// claim_foreground(pgid)
//    Mark `pgid` as the current foreground process group.

int claim_foreground(pid_t pgid);


// set_signal_handler(signo, handler)
//    Install handler `handler` for signal `signo`. `handler` can be SIG_DFL
//    to install the default handler, or SIG_IGN to ignore the signal. Return
//    0 on success, -1 on failure. See `man 2 sigaction` or `man 3 signal`.

inline int set_signal_handler(int signo, void (*handler)(int)) {
    struct sigaction sa;
    sa.sa_handler = handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    return sigaction(signo, &sa, NULL);
}


inline constexpr shell_parser::operator bool() const {
    return _s != _stop;
}

inline constexpr bool shell_parser::empty() const {
    return _s == _stop;
}

inline std::string shell_parser::str() const {
    return std::string(_s, _stop - _s);
}

inline shell_tokenizer shell_parser::first_token() const {
    return shell_tokenizer(_s, _stop);
}

inline constexpr shell_tokenizer::operator bool() const {
    return _s != _end;
}

inline constexpr bool shell_tokenizer::empty() const {
    return _s == _end;
}

inline constexpr int shell_tokenizer::type() const {
    return _type;
}

#endif
