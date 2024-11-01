#include "sh61.hh"
#include <cctype>
#include <cstring>
#include <sstream>

// isshellspecial(ch)
//    Test if `ch` is a command that's special to the shell (that ends
//    a command word).

inline bool isshellspecial(int ch) {
    return ch == '<' || ch == '>' || ch == '&' || ch == '|' || ch == ';'
        || ch == '(' || ch == ')' || ch == '#';
}

inline const char* skip_shell_space(const char* s, const char* end) {
    while (s != end && isspace((unsigned char) *s)) {
        ++s;
    }
    // Skip to end of line if comment
    if (s != end && *s == '#') {
        s = end;
    }
    return s;
}

shell_tokenizer::shell_tokenizer(const char* str)
    : _s(str), _end(str + strlen(str)), _len(0) {
    next();
}

shell_tokenizer::shell_tokenizer(const char* first, const char* last)
    : _s(first), _end(last), _len(0) {
    next();
}

void shell_tokenizer::next() {
    _s = skip_shell_space(_s + _len, _end);
    _len = 0;
    _quoted = false;

    // Return early at end of command line
    if (_s == _end) {
        _type = TYPE_SEQUENCE;
        return;
    }

    // Read token starting at _s, setting _type, _len, and _quoted.
    // - _len: Length of token in characters.
    // - _type: Type of token (one of the TYPE_ constants).
    // - _quoted: True iff this token contains quotes or escapes.
    const char* p = _s;
    while (p != _end && isdigit((unsigned char) *p)) {
        ++p;
    }
    if (p != _end && (*p == '<' || *p == '>')) {
        // Redirection
        ++p;
        if (p != _end && *p == '>') {
            ++p;
        } else {
            while (p != _end && isdigit((unsigned char) *p)) {
                ++p;
            }
        }
        _type = TYPE_REDIRECT_OP;

    } else if (p == _s
               && (*p == '&' || *p == '|')
               && p + 1 != _end
               && p[1] == p[0]) {
        // Two-character operator
        _type = (*p == '&' ? TYPE_AND : TYPE_OR);
        p += 2;

    } else if (p == _s
               && isshellspecial((unsigned char) *p)) {
        // One-character operator
        if (*p == ';') {
            _type = TYPE_SEQUENCE;
        } else if (*p == '&') {
            _type = TYPE_BACKGROUND;
        } else if (*p == '|') {
            _type = TYPE_PIPE;
        } else if (*p == '(') {
            _type = TYPE_LPAREN;
        } else if (*p == ')') {
            _type = TYPE_RPAREN;
        } else {
            _type = TYPE_OTHER;
        }
        ++p;

    } else {
        // Ordinary word (command, argument, or filename)
        _type = TYPE_NORMAL;
        int curquote = 0;
        // Consume characters up to the end of the token.
        while (p != _end
               && (curquote
                   || (!isspace((unsigned char) *p)
                       && !isshellspecial((unsigned char) *p)))) {
            if ((*p == '\"' || *p == '\'') && !curquote) {
                curquote = *p;
                _quoted = true;
            } else if (*p == curquote) {
                curquote = 0;
            } else if (*p == '\\' && p + 1 != _end && curquote != '\''){
                _quoted = true;
                ++p;
            }
            ++p;
        }
    }
    _len = p - _s;
}

std::string shell_tokenizer::str() const {
    if (!_quoted) {
        return std::string(_s, _len);
    }
    std::ostringstream build;
    int curquote = 0;
    for (unsigned pos = 0; pos != _len; ++pos) {
        if ((_s[pos] == '\"' || _s[pos] == '\'') && !curquote) {
            curquote = _s[pos];
        } else if (_s[pos] == curquote) {
            curquote = 0;
        } else if (_s[pos] == '\\'
                   && _s[pos+1] != '\0'
                   && curquote != '\'') {
            build << _s[pos+1];
            ++pos;
        } else {
            build << _s[pos];
        }
    }
    return build.str();
}

const char* shell_tokenizer::type_name() const {
    switch (_type) {
    case TYPE_NORMAL:       return "TYPE_NORMAL";
    case TYPE_REDIRECT_OP:  return "TYPE_REDIRECT_OP";
    case TYPE_SEQUENCE:     return "TYPE_SEQUENCE";
    case TYPE_BACKGROUND:   return "TYPE_BACKGROUND";
    case TYPE_PIPE:         return "TYPE_PIPE";
    case TYPE_AND:          return "TYPE_AND";
    case TYPE_OR:           return "TYPE_OR";
    case TYPE_LPAREN:       return "TYPE_LPAREN";
    case TYPE_RPAREN:       return "TYPE_RPAREN";
    case TYPE_OTHER:        return "TYPE_OTHER";
    default:                return "TYPE_UNKNOWN";
    }
}


shell_parser::shell_parser(const char* str)
    : shell_parser(str, str + strlen(str), str + strlen(str)) {
}

shell_parser::shell_parser(const char* first, const char* last)
    : shell_parser(first, last, last) {
}

shell_parser::shell_parser(const char* first, const char* stop, const char* last)
    : _s(first), _stop(stop), _end(last) {
    _s = skip_shell_space(_s, _stop);
}

shell_parser shell_parser::first_conditional() const {
    return first_delimited((1 << TYPE_SEQUENCE) | (1 << TYPE_BACKGROUND));
}

void shell_parser::next_conditional() {
    next_delimited((1 << TYPE_SEQUENCE) | (1 << TYPE_BACKGROUND));
}

int shell_parser::op() const {
    shell_tokenizer it(_stop, _end);
    return it.type();
}

const char* shell_parser::op_name() const {
    shell_tokenizer it(_stop, _end);
    return it.type_name();
}

shell_parser shell_parser::first_pipeline() const {
    return first_delimited((1 << TYPE_SEQUENCE) | (1 << TYPE_BACKGROUND) | (1 << TYPE_AND) | (1 << TYPE_OR));
}

void shell_parser::next_pipeline() {
    next_delimited((1 << TYPE_SEQUENCE) | (1 << TYPE_BACKGROUND) | (1 << TYPE_AND) | (1 << TYPE_OR));
}

shell_parser shell_parser::first_command() const {
    return first_delimited((1 << TYPE_SEQUENCE) | (1 << TYPE_BACKGROUND) | (1 << TYPE_AND) | (1 << TYPE_OR) | (1 << TYPE_PIPE));
}

void shell_parser::next_command() {
    next_delimited((1 << TYPE_SEQUENCE) | (1 << TYPE_BACKGROUND) | (1 << TYPE_AND) | (1 << TYPE_OR) | (1 << TYPE_PIPE));
}

shell_parser shell_parser::first_delimited(unsigned long fl) const {
    shell_tokenizer it(_s, _stop);
    while (it.type() >= 0 && (fl & (1 << it.type())) == 0) {
        it.next();
    }
    return shell_parser(_s, it._s, _stop);
}

void shell_parser::next_delimited(unsigned long fl) {
    shell_tokenizer it(_stop, _end);
    if (it.type() >= 0 && (fl & (1 << it.type())) != 0) {
        it.next();
    }
    _s = it._s;
    while (it.type() >= 0 && (fl & (1 << it.type())) == 0) {
        it.next();
    }
    _stop = it._s;
}


// claim_foreground(pgid)
//    Mark `pgid` as the current foreground process group for this terminal.
//    This uses some ugly Unix warts, so we provide it for you.
int claim_foreground(pid_t pgid) {
    // YOU DO NOT NEED TO UNDERSTAND THIS.

    // Initialize state first time we're called.
    static int ttyfd = -1;
    static int shell_owns_foreground = 0;
    static pid_t shell_pgid = -1;
    if (ttyfd < 0) {
        // We need a fd for the current terminal, so open /dev/tty.
        int fd = open("/dev/tty", O_RDWR);
        assert(fd >= 0);
        // Re-open to a large file descriptor (>=10) so that pipes and such
        // use the expected small file descriptors.
        ttyfd = fcntl(fd, F_DUPFD, 10);
        assert(ttyfd >= 0);
        close(fd);
        // The /dev/tty file descriptor should be closed in child processes.
        fcntl(ttyfd, F_SETFD, FD_CLOEXEC);
        // Only mess with /dev/tty's controlling process group if the shell
        // is in /dev/tty's controlling process group.
        shell_pgid = getpgrp();
        shell_owns_foreground = (shell_pgid == tcgetpgrp(ttyfd));
    }

    // Set the terminal's controlling process group to `p` (so processes in
    // group `p` can output to the screen, read from the keyboard, etc.).
    if (shell_owns_foreground && pgid) {
        return tcsetpgrp(ttyfd, pgid);
    } else if (shell_owns_foreground) {
        return tcsetpgrp(ttyfd, shell_pgid);
    } else {
        return 0;
    }
}
