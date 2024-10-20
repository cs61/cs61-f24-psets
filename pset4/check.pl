#! /usr/bin/perl -w

# check.pl
#    This program runs the tests in io61 and stdio versions.
#    It compares their outputs and measures time and memory usage.
#    It tries to prevent disaster: if your code looks like it's
#    generating an infinite-length file, or using too much memory,
#    check.pl will kill it.
#
#    To add tests of your own, scroll down to the bottom. It should
#    be relatively clear what to do.

use Time::HiRes qw(gettimeofday);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use POSIX;
use Scalar::Util qw(looks_like_number);
use List::Util qw(shuffle min max);
use Config;
my $nkilled = 0;
my $nerror = 0;
my (@ratios, @runtimes, @basetimes, @alltests);
my %fileinfo;
sub first (@) { return $_[0]; }
my $CHECKSUM = first(grep {-x $_} ("/usr/bin/md5sum", "/sbin/md5", "/bin/false"));
my $TTY = (`tty` or "/dev/tty");
chomp($TTY);
my (@sig_name) = split(/ /, $Config{"sig_name"});
my $SIGINT = 0;
while ($sig_name[$SIGINT] ne "INT") {
    ++$SIGINT;
}

sub nonemptyenv ($) {
    my ($e) = @_;
    return exists($ENV{$e}) && $ENV{$e} ne "" && $ENV{$e} ne " ";
}

sub boolenv ($) {
    my ($e) = @_;
    return nonemptyenv($e) && $ENV{$e} ne "0" ? 1 : 0;
}

eval { require "syscall.ph" };

my $ROOT = "";
my %param;
my $SEQTEST = 1;
my $VERBOSE = boolenv("V");

my ($Red, $Redctx, $Green, $Greenctx, $Cyan, $Cyanctx, $Ylo, $Yloctx, $Off) = ("\x1b[01;31m", "\x1b[0;31m", "\x1b[01;32m", "\x1b[0;32m", "\x1b[01;36m", "\x1b[0;36m", "\x1b[01;33m", "\x1b[0;33m", "\x1b[0m");
my ($color) = -t STDERR && -t STDOUT;
if ($color) {
    $ENV{"ASAN_OPTIONS"} = "color=always" if !exists($ENV{"ASAN_OPTIONS"});
    $ENV{"TSAN_OPTIONS"} = "color=always" if !exists($ENV{"TSAN_OPTIONS"});
    $ENV{"UBSAN_OPTIONS"} = "color=always" if !exists($ENV{"UBSAN_OPTIONS"});
} else {
    $Red = $Redctx = $Green = $Greenctx = $Cyan = $Cyanctx = $Ylo = $Yloctx = $Off = "";
}


$SIG{"CHLD"} = sub {};
$SIG{"TSTP"} = "DEFAULT";
$SIG{"TTOU"} = "IGNORE";
my $run61_pid;
open(TTY, "+<", $TTY) or die "can't open $TTY: $!";

sub decache ($) {
    my ($fn) = @_;
    if (defined(&{"SYS_fadvise64"}) && open(DECACHE, "<", $fn)) {
        syscall &SYS_fadvise64, fileno(DECACHE), 0, -s DECACHE, 4;
        close(DECACHE);
    }
}

sub make_datafile ($) {
    my ($filename) = @_;
    my ($size) = $fileinfo{$filename}->[2];
    my ($cmd) = $filename =~ /-rev/ ? "rev" : "cat";
    my ($src) = $filename =~ /\.bin$/ ? "/bin/sh" : "/usr/share/dict/words";
    die if $ROOT ne "" && $filename =~ /\A${ROOT}/;
    my ($rootfn) = "${ROOT}$filename";
    my ($first_offset) = "";
    if (defined($fileinfo{$filename}->[3]) && $fileinfo{$filename}->[3]) {
        $first_offset = " | tail -c +" . $fileinfo{$filename}->[3];
    }
    if (!-r $rootfn || !defined(-s $rootfn) || -s $rootfn != $size) {
        while (!defined(-s $rootfn) || -s $rootfn < $size) {
            system("$cmd $src$first_offset >> $rootfn");
            $first_offset = "";
        }
        truncate($rootfn, $size);
    }
    $fileinfo{$filename} = [-M $rootfn, -C $rootfn, $size];
}

sub verify_file ($) {
    my ($filename) = @_;
    if (exists($fileinfo{$filename})
        && (!-r "${ROOT}$filename"
            || $fileinfo{$filename}->[0] != -M "${ROOT}$filename"
            || $fileinfo{$filename}->[1] != -C "${ROOT}$filename")) {
        truncate("${ROOT}$filename", 0);
        make_datafile($filename);
    }
    return -s "${ROOT}$filename";
}

sub file_md5sum ($) {
    my ($x) = `$CHECKSUM $_[0]`;
    $x =~ s{\A(\S+).*\z}{$1}s;
    return $x;
}

sub unparse_signal ($) {
    my ($s) = @_;
    my (@sigs) = split(" ", $Config{sig_name});
    return "unknown signal $s" if $s >= @sigs;
    return "illegal instruction" if $sigs[$s] eq "ILL";
    return "abort signal" if $sigs[$s] eq "ABRT";
    return "floating point exception" if $sigs[$s] eq "FPE";
    return "segmentation fault" if $sigs[$s] eq "SEGV";
    return "broken pipe" if $sigs[$s] eq "PIPE";
    return "SIG" . $sigs[$s];
}

sub run_sh61_pipe ($$;$) {
    my ($text, $fd, $size) = @_;
    my ($n, $buf) = (0, "");
    return $text if !defined($fd);
    while ((!defined($size) || length($text) <= $size)
           && defined(($n = POSIX::read($fd, $buf, 8192)))
           && $n > 0) {
        $text .= substr($buf, 0, $n);
    }
    return $text;
}

sub run_sh61 ($;%) {
    my($command, %opt) = @_;
    my($outfile) = exists($opt{"stdout"}) ? $opt{"stdout"} : undef;
    my($size_limit_file) = exists($opt{"size_limit_file"}) ? $opt{"size_limit_file"} : $outfile;
    $size_limit_file = [$size_limit_file] if $size_limit_file && !ref($size_limit_file);
    my($size_limit) = exists($opt{"size_limit"}) ? $opt{"size_limit"} : undef;
    my($dir) = exists($opt{"dir"}) ? $opt{"dir"} : undef;
    if (defined($dir) && $size_limit_file) {
        $dir =~ s{/+$}{};
        $size_limit_file = [map { m{\A/} ? $_ : "$dir/$_" } @$size_limit_file];
    }
    pipe(PR, PW);
    pipe(OR, OW) or die "pipe";
    fcntl(OR, F_SETFL, fcntl(OR, F_GETFL, 0) | O_NONBLOCK);
    1 while waitpid(-1, WNOHANG) > 0;
    print STDERR $command, "\n" if $VERBOSE;

    my($preutime, $prestime, $precutime, $precstime) = times();

    $run61_pid = fork();
    if ($run61_pid == 0) {
        $SIG{"INT"} = "DEFAULT";
        POSIX::setpgid(0, 0) or die("child setpgid: $!\n");
        POSIX::tcsetpgrp(fileno(TTY), $$) or die("child tcsetpgrp: $!\n");
        defined($dir) && chdir($dir);
        close(TTY); # for explicitness: Perl will close by default

        close(PR);
        POSIX::dup2(fileno(PW), 100);
        close(PW);

        my($fn) = defined($opt{"stdin"}) ? $opt{"stdin"} : "/dev/null";
        if (defined($fn) && $fn ne "/dev/stdin") {
            my($fd) = POSIX::open($fn, O_RDONLY);
            POSIX::dup2($fd, 0);
            POSIX::close($fd) if $fd != 0;
            fcntl(STDIN, F_SETFD, fcntl(STDIN, F_GETFD, 0) & ~FD_CLOEXEC);
        }

        close(OR);
        if (!defined($outfile) || $outfile ne "/dev/stdout") {
            open(OW, ">", $outfile) || die if defined($outfile) && $outfile ne "pipe";
            POSIX::dup2(fileno(OW), 1);
            POSIX::dup2(fileno(OW), 2);
            close(OW) if fileno(OW) != 1 && fileno(OW) != 2;
            fcntl(STDOUT, F_SETFD, fcntl(STDOUT, F_GETFD, 0) & ~FD_CLOEXEC);
            fcntl(STDERR, F_SETFD, fcntl(STDERR, F_GETFD, 0) & ~FD_CLOEXEC);
        }

        { exec($command) };
        print STDERR "error trying to run $command: $!\n";
        exit(1);
    }

    POSIX::setpgid($run61_pid, $run61_pid);    # might fail if child exits quickly
    POSIX::tcsetpgrp(fileno(TTY), $run61_pid); # might fail if child exits quickly

    my($before) = Time::HiRes::time();
    my($died) = 0;
    my($time_limit) = exists($opt{"time_limit"}) ? $opt{"time_limit"} : 0;
    my($out, $buf, $nb) = ("", "");
    my($answer) = exists($opt{"answer"}) ? $opt{"answer"} : {};
    $answer->{"command"} = $command;
    my($sigint_at) = defined($opt{"int_delay"}) ? $before + $opt{"int_delay"} : undef;
    my($sigint_state) = defined($sigint_at) ? 1 : 0;

    close(PW);
    close(OW);

    eval {
        do {
            my $delta = 0.3;
            if ($sigint_at) {
                my $now = Time::HiRes::time();
                $delta = min($delta, $sigint_at < $now + 0.02 ? 0.1 : $sigint_at - $now);
            }
            Time::HiRes::usleep($delta * 1e6) if $delta > 0;

            if (waitpid($run61_pid, WNOHANG) > 0) {
                $answer->{"status"} = $?;
                die "!";
            }
            if ($sigint_state == 1 && Time::HiRes::time() >= $sigint_at) {
                my $pgrp = POSIX::tcgetpgrp(fileno(TTY));
                if ($pgrp != getpgrp()) {
                    kill(-$SIGINT, $pgrp);
                    $sigint_state = 2;
                }
            }
            if (defined($size_limit) && $size_limit_file && @$size_limit_file) {
                my $len = 0;
                $out = run_sh61_pipe($out, fileno(OR), $size_limit);
                foreach my $fname (@$size_limit_file) {
                    my $flen = $fname eq "pipe" ? length($out) : -s $fname;
                    $len += $flen if $flen;
                }
                if ($len > $size_limit) {
                    $died = "output file size $len, expected <= $size_limit";
                    die "!";
                }
            }
        } while (Time::HiRes::time() < $before + $time_limit);
        if (waitpid($run61_pid, WNOHANG) > 0) {
            $answer->{"status"} = $?;
        } else {
            $died = sprintf("timeout after %.2fs", $time_limit);
        }
    };

    my($delta) = Time::HiRes::time() - $before;
    $answer->{"time"} = $delta;

    if (exists($answer->{"status"})
        && ($answer->{"status"} & 127) == $SIGINT
        && !defined($opt{"int_delay"})) {
        # assume user is trying to quit
        kill -9, $run61_pid;
        exit(1);
    }
    if (exists($answer->{"status"})
        && exists($opt{"delay"})
        && $opt{"delay"} > 0) {
        Time::HiRes::usleep($opt{"delay"} * 1e6);
    }
    if (exists($opt{"nokill"})) {
        $answer->{"pgrp"} = $run61_pid;
    } else {
        kill -9, $run61_pid;
        waitpid($run61_pid, 0);
        POSIX::tcsetpgrp(fileno(TTY), getpgrp());
    }
    $run61_pid = 0;

    my($postutime, $poststime, $postcutime, $postcstime) = times();
    $answer->{"utime"} = $postcutime - $precutime;
    $answer->{"stime"} = $postcstime - $precstime;

    if ($died) {
        $answer->{"killed"} = $died;
        close(OR);
        close(PR);
        return $answer;
    }

    $nb = POSIX::read(fileno(PR), $buf, 2000);
    close(PR);
    $buf = $nb > 0 ? substr($buf, 0, $nb) : "";

    while ($buf =~ m,\"(.*?)\"\s*:\s*([\d.]+),g) {
        $answer->{$1} = $2;
    }
    $answer->{"time"} = $delta if !defined($answer->{"time"});
    $answer->{"time"} = $delta if $answer->{"time"} <= 0.95 * $delta;
    $answer->{"utime"} = $delta if !defined($answer->{"utime"});
    $answer->{"stime"} = $delta if !defined($answer->{"stime"});
    $answer->{"maxrss"} = -1 if !defined($answer->{"maxrss"});

    if (defined($outfile) && $outfile ne "pipe") {
        $out = "";
        close(OR);
        open(OR, "<", (defined($dir) ? "$dir/$outfile" : $outfile));
    }
    $out = run_sh61_pipe($out, fileno(OR), $size_limit);
    close(OR);

    if ($size_limit_file && @$size_limit_file) {
        my($len, @sums) = 0;
        foreach my $fname (@$size_limit_file) {
            my($sz) = $fname eq "pipe" ? length($out) : -s $fname;
            $len += $sz if defined($sz);
            if ($VERBOSE && $fname eq "pipe") {
                # XXX
            } elsif (($VERBOSE || $param{"MAKETRIALLOG"} || defined($param{"TRIALLOG"}))
                     && -f $fname
                     && $opt{"compare"}) {
                push @sums, file_md5sum($fname);
            }
        }
        $answer->{"outputsize"} = $len;
        $answer->{"md5sum"} = join(" ", @sums) if @sums;
    }

    my(@stderr);
    if ($out) {
        my($tx) = "";
        foreach my $l (split(/\n/, $out)) {
            $tx .= ($tx eq "" ? "" : "\n        : ") . $l if $l ne "";
        }
        if ($tx ne "" && exists($answer->{"trial"})) {
            push @stderr, "    ${Redctx}STDERR (trial " . $answer->{"trial"} . "): $tx${Off}\n";
        } elsif ($tx ne "") {
            push @stderr, "    ${Redctx}STDERR: $tx${Off}\n";
        }
    }
    if (exists($answer->{"status"})
        && ($answer->{"status"} & 127)) {
        my $signo = $answer->{"status"} & 127;
        my $signame = unparse_signal($signo);
        $signame = defined($signame) ? $signame : "signal $signo";
        if (exists($answer->{"trial"})) {
            push @stderr, "    ${Redctx}KILLED by $signame (trial " . $answer->{"trial"} . ")${Off}\n";
        } else {
            push @stderr, "    ${Redctx}KILLED by $signame${Off}\n";
        }
        if ($signo == $SIGINT) {
            kill $SIGINT, 0;
        }
    }
    if (@stderr) {
        $answer->{"stderr"} = join("", @stderr);
        $answer->{"stderr"} =~ s/\s*\z/\n/s;
    }

    return $answer;
}


# test matching
my(@RESTRICT_TESTS, @ALLOW_TESTS);

sub split_testid ($) {
    my ($testid) = @_;
    if ($_[0] =~ /\A([A-Za-z]*)(\d*)([A-Za-z]*)\z/) {
        return (uc($1), +$2, lc($3));
    } else {
        return ($_[0], "", "");
    }
}

sub split_testmatch ($) {
    my @t;
    while ($_[0] =~ m/(?:\A|[\s,])([A-Za-z]*|\*)-?(\*|\d*)(-[A-Za-z]*\d+|-|[*.]|[A-Za-z][-A-Za-z]*|)(?=[\s,]|\z)/g) {
        my ($p, $n, $s) = (uc($1), $2, $3);
        if ($s =~ /\A-([A-Za-z]+)(\d+)\z/) {
            next if uc($1) ne $p || $n eq "" || $n eq "*";
            push(@t, [$p, +$n, "-$2"]);
        } else {
            next if ($n eq "" && $s ne "") || ($n eq "*" && $s eq "*");
            push(@t, [$p, $n ne "" && $n ne "*" ? +$n : "", lc($s)]);
        }
    }
    @t;
}

sub match_testid ($$) {
    my ($id, $match) = @_;
    if (ref $match) {
        my ($pfx, $num, $sfx) = split_testid($id);
        my ($apfx, $anum, $asfx) = @$match;
        # check prefix
        return 0 if $apfx ne "" && $apfx ne "*" && $pfx ne $apfx;
        # check test number
        return 1 if $anum eq "";
        my $anum2 = $anum;
        if (substr($asfx, 0, 1) eq "-") {
            $anum2 = $asfx eq "-" ? $num : +substr($asfx, 1);
            $asfx = "";
        }
        return 0 if $num < $anum || $num > $anum2;
        # check test suffix
        return 1 if $asfx eq "" || $asfx eq "*";
        return ($sfx eq "") if $asfx eq ".";
        while ($asfx =~ /([a-z])(-\z|-[a-z]|(?!-))/g) {
            return 1 if $sfx eq $1;
            return 1 if $sfx gt $1 && $2 ne "" && ($2 eq "-" || $sfx le substr($2, 1));
        }
        return 0;
    } else {
        foreach my $m (split_testmatch($match)) {
            return 1 if &match_testid($id, $m);
        }
        return 0;
    }
}

sub testid_runnable ($) {
    my ($testid) = @_;
    return (!@RESTRICT_TESTS || !grep { match_testid($testid, $_) } @RESTRICT_TESTS)
        && (!@ALLOW_TESTS || grep { match_testid($testid, $_) } @ALLOW_TESTS);
}


sub read_triallog ($) {
    my($buf);
    open(TRIALLOG, "<", $_[0]) or die "$_[0]: $!\n";
    while (defined($buf = <TRIALLOG>)) {
        my($t) = {};
        while ($buf =~ m,"([^"]*)"\s*:\s*([\d.]+),g) {
            $t->{$1} = $2 + 0;
        }
        while ($buf =~ m,"([^"]*)"\s*:\s*"([^"]*)",g) {
            $t->{$1} = $2;
        }
        push @alltests, $t if keys(%$t);
    }
    close(TRIALLOG);
}

my (%MAKE_TARGETS, @MAKE_TARGETS);

sub add_make_targets ($) {
    my ($command) = @_;
    return if $param{"NOMAKE"};
    my @t;
    while ($command =~ m/(?:\A|\s)(\.\/[-_A-Za-z0-9]+)(?=\z|\s)/g) {
        push @t, $1;
    }
    foreach my $t (@t) {
        next if $command !~ m/(?:\A|[|&;]\s*|'\|'\s*|\.\/socketpipe\s*(?:-B\s*\d+\s*|))$t/;
        $t = substr($t, 2);
        if (!exists($MAKE_TARGETS{$t})) {
            push @MAKE_TARGETS, $t;
            $MAKE_TARGETS{$t} = 1;
        }
    }
}

sub maybe_make ($) {
    my ($command) = @_;
    add_make_targets $command;
    if (@MAKE_TARGETS) {
        foreach my $k ("V", "O", "DEFS", "NDEBUG", "SAN") {
            unshift @MAKE_TARGETS, $k . "=" . $param{$k} if defined($param{$k});
        }
        unshift @MAKE_TARGETS, "-s" if !$VERBOSE;
        unshift @MAKE_TARGETS, "make";
        my ($system_pid) = fork();
        if ($system_pid == 0) {
            if ($param{"MAKESILENT"}) {
                open(STDOUT, ">", "/dev/null") or exit(1);
                open(STDERR, ">", "/dev/null") or exit(1);
            }
            exec(@MAKE_TARGETS) or exit(1);
        }
        my ($ret) = -1;
        if ($system_pid > 0) {
            my $kid = waitpid($system_pid, 0);
            $ret = $kid == $system_pid ? $? : -1;
        }
        if ($ret != 0) {
            if (($ret & 127) == $SIGINT) {
                # no error
            } elsif ($param{"MAKESILENT"} && ($ret & 12)) {
                print STDERR "${Red}ERROR: Cannot build secret tests${Off}\n";
            } else {
                print STDERR "${Red}ERROR: Cannot ", join(" ", @MAKE_TARGETS), "${Off}\n";
            }
            exit 1;
        }
        @MAKE_TARGETS = ();
    }
}

my(@workq, %command_max_size, %command_trials);

sub find_tests ($$$) {
    my ($id, $type, $qcommand) = @_;
    grep {
        $_->{"id"} eq $id && $_->{"type"} eq $type && $_->{"qcommand"} eq $qcommand
    } @alltests;
}

sub enqueue ($$$%) {
    my ($id, $command, $desc, %opt) = @_;
    return if !testid_runnable($id);
    my $expansion = $opt{"expansion"};
    $expansion = 1 if !$expansion;
    my $perf = exists($opt{"perf"}) ? $opt{"perf"} : 1;
    my $check_random = exists($opt{"check_random"}) ? $opt{"check_random"} : 0;
    my $compare;
    if (!exists($opt{"compare"}) || !$opt{"compare"}) {
        $compare = $SEQTEST;
    } else {
        $compare = $opt{"compare"} > 0;
    }
    my $stdio = !$param{"NOSTDIO"};
    $stdio = 0 if $perf == 0 && (!$compare || defined($opt{"expect"}));

    # verify input files
    my(@infiles);
    my($insize) = 0;
    while ($command =~ m{\b([-a-z0-9/]+\.(?:txt|bin))\b}g) {
        if (exists($fileinfo{$1})) {
            push @infiles, $1;
            $insize += verify_file($1);
        }
    }
    $insize = $opt{"insize"} if exists($opt{"insize"});

    # prepare stdio command
    my($stdiocmd) = $command;
    $stdiocmd =~ s<(\./)([-a-z]*61)><${1}stdio-$2>g;
    $stdiocmd =~ s<outputs/><stdoutputs/>g;
    my($stdio_qitem) = {
        "id" => $id, "desc" => $desc, "type" => "stdio",
        "command" => $stdiocmd,
        "maincommand" => $command, "stdiocommand" => $stdiocmd,
        "count" => 0, "elapsed" => 0, "errors" => 0,
        "nleft" => $param{"STDIOTRIALS"},
        "infiles" => \@infiles, "outfiles" => [],
        "insize" => $insize, "check_max_size" => 0, "opt" => \%opt,
        "compare" => $compare, "check_random" => 0
    };
    while ($stdiocmd =~ m{(stdoutputs/[^\s'"|()&<>;!]*\.(?:txt|bin))}g) {
        push @{$stdio_qitem->{"outfiles"}}, $1;
    }
    my $nstdiotrials = 0;
    if ($stdio) {
        $nstdiotrials = $perf ? $param{"STDIOTRIALS"} : 1;
        for (my $i = 0; $i < $nstdiotrials; ++$i) {
            push @workq, $stdio_qitem;
        }
    }

    # prepare maximum size, possibly using triallog
    $command_max_size{$command} = $expansion * $insize;
    foreach my $t (find_tests($id, "stdio", $stdiocmd)) {
        if (exists($t->{"outputsize"})
            && $t->{"outputsize"} > $command_max_size{$command}) {
            $command_max_size{$command} = $t->{"outputsize"};
        }
    }

    # prepare normal command
    my $runcommand = $command;
    $runcommand =~ s{(\./[-a-z]*61)}{strace -o strace.out $1}
        if $param{"STRACE"};
    my $trials = $perf ? $param{"TRIALS"} : 1;
    $trials = 0 if $param{"NOYOURCODE"};
    my $your_qitem = {
        "id" => $id, "desc" => $desc, "type" => "yourcode",
        "command" => $runcommand,
        "maincommand" => $command, "stdiocommand" => $stdiocmd,
        "count" => 0, "elapsed" => 0, "errors" => 0, "nleft" => $trials,
        "infiles" => \@infiles, "outfiles" => [],
        "insize" => $insize, "check_max_size" => 1, "opt" => \%opt,
        "compare" => $compare, "check_random" => $check_random,
        "perf" => $perf, "has_stdio" => $stdio
    };
    while ($command =~ m{(outputs/[^\s'"|()&<>;!]*\.(?:txt|bin))}g) {
        push @{$your_qitem->{"outfiles"}}, $1;
    }
    for (my $i = 0; $i < $trials; ++$i) {
        push @workq, $your_qitem;
    }
    $command_trials{$command} = $nstdiotrials + $trials;
}

my $qitem_last_error;

sub run_qitem ($) {
    my ($qitem) = @_;
    my ($maincommand) = $qitem->{"maincommand"};
    $qitem_last_error = 0;
    $qitem->{"nleft"} -= 1;
    $command_trials{$maincommand} -= 1;
    my ($trialtime) = $qitem->{"type"} eq "stdio" ? $param{"STDIOTRIALTIME"} : $param{"TRIALTIME"};
    if ($qitem->{"errors"} > 1) {
        $nprev = $qitem->{"count"};
        $qitem_last_error = sprintf("previous %s had too many errors", $nprev == 1 ? "trial" : "$nprev trials");
        return 0;
    } elsif ($trialtime > 0 && $qitem->{"elapsed"} >= $trialtime) {
        $nprev = $qitem->{"count"};
        $qitem_last_error = sprintf("previous %s took %gs, limit %gs", $nprev == 1 ? "trial" : "$nprev trials", int($qitem->{"elapsed"} * 10 + 0.5) / 10, int($trialtime * 10 + 0.5) / 10);
        return 0;
    }

    foreach my $f (@{$qitem->{"infiles"}}) {
        decache($ROOT . $f);
    }
    Time::HiRes::usleep(100000);

    my ($time_limit) = $qitem->{"type"} eq "stdio" ? 60 : $param{"MAXTIME"};
    my ($max_size) = undef;
    if ($qitem->{"check_max_size"}) {
        $max_size = $command_max_size{$maincommand} * 2;
    }

    # while (my ($k, $v) = each %$qitem) {
    #     print ">>>> Q >> $k $v\n";
    # }

    my ($command) = $qitem->{"command"};
    die if $command =~ /${ROOT}/ && $ROOT ne "";
    $command =~ s/\b(inputs|outputs|stdoutputs)\//${ROOT}$1\//g;
    my (@size_limit_files) = @{$qitem->{"outfiles"}};
    map { s/\b(inputs|outputs|stdoutputs)\//${ROOT}$1\// } @size_limit_files;

    my ($t) = run_sh61($command,
                       "size_limit_file" => \@size_limit_files,
                       "time_limit" => $time_limit,
                       "size_limit" => $max_size,
                       "answer" => {"id" => $qitem->{"id"},
                                    "type" => $qitem->{"type"},
                                    "trial" => $qitem->{"count"} + 1},
                       "compare" => $qitem->{"compare"});
    $t->{"qcommand"} = $qitem->{"command"};
    push @alltests, $t;

    $qitem->{"count"} += 1;
    $qitem->{"errors"} += 1 if exists($t->{"killed"});
    $qitem->{"elapsed"} += $t->{"time"};

    if (!$max_size
        && exists($t->{"outputsize"})
        && $t->{"outputsize"} > $command_max_size{$maincommand}) {
        $command_max_size{$maincommand} = $t->{"outputsize"};
    }

    $t;
}

sub check_trial_output ($$$) {
    my ($tt, $stdiot, $qitem) = @_;

    my $expect = $qitem->{"opt"}->{"expect"};
    $expect =~ s/\b(inputs|outputs|stdoutputs)\//${ROOT}$1\// if $expect;

    my $output_size;
    if ($expect) {
        $output_size = -s $expect;
    } elsif ($stdiot && exists($stdiot->{"outputsize"})) {
        $output_size = $stdiot->{"outputsize"};
    }
    if (defined($output_size)
        && (!defined($tt->{"outputsize"}) || $tt->{"outputsize"} != $output_size)) {
        $tt->{"different_size"} = $output_size;
    }

    my (@content_check, $md5sum_check);
    if (!$param{"NOYOURCODE"} && $qitem->{"compare"}) {
        @content_check = @{$qitem->{"outfiles"}}
            if $expect || (!$param{"NOSTDIO"} && $stdiot);
        $md5sum_check = $stdiot->{"md5sum"}
            if $param{"NOSTDIO"} && $stdiot && exists($stdiot->{"md5sum"});
    }
    foreach my $fname (@content_check) {
        my $rootfname = $fname;
        $rootfname =~ s/\b(inputs|outputs|stdoutputs)\//${ROOT}$1\//;
        my $basefname = $expect;
        if (!defined($basefname)) {
            $basefname = $rootfname;
            $basefname =~ s/\boutputs\//stdoutputs\//;
        }
        print STDERR "cmp $rootfname $basefname 2>&1\n" if $VERBOSE;
        my $r = scalar(`cmp $rootfname $basefname 2>&1`);
        if ($? && $r) {
            my $msg1 = "$fname differs from";
            if ($expect) {
                $msg1 .= " expected $expect";
            } else {
                $msg1 .= " stdio's $basefname";
            }

            chomp $r;
            my $msg2 = "(${r})";

            $tt->{"different_content"} = $msg1;
            $tt->{"different_content_context"} = $msg2;
        }
    }

    if (!exists($tt->{"different_content"})
        && $md5sum_check
        && exists($tt->{"md5sum"})
        && $tt->{"md5sum"} ne $md5sum_check) {
        my $fname = join("+", @{$qitem->{"outfiles"}});
        my $msg1 = "$fname differs from expected output";

        $tt->{"different_content"} = $msg1;
        $tt->{"different_content_context"} = "(got md5sum " . $tt->{"md5sum"}
            . ", expected $md5sum_check)";
    }

    if (!exists($tt->{"different_content"})
        && !$param{"NOYOURCODE"}
        && $qitem->{"check_random"}) {
        my(@random_check) = @{$qitem->{"outfiles"}};
        foreach my $fname (@random_check) {
            my $rootfname = $fname;
            $rootfname =~ s/\b(inputs|outputs|stdoutputs)\//${ROOT}$1\//;
            my $r = scalar(`./randcheck61 $rootfname`);
            if ($? && $r) {
                $tt->{"different_content"} = "$fname differs from expectation, should be random";
                last;
            }
        }
    }
}

sub first_trial ($$$) {
    my ($id, $type, $qitem) = @_;
    my $command = $qitem->{$type eq "stdio" ? "stdiocommand" : "maincommand"};
    my (@tests) = find_tests($id, $type, $command);
    @tests ? $tests[0] : undef;
}

sub median_trial ($$$) {
    my ($id, $type, $qitem) = @_;
    my $command = $qitem->{$type eq "stdio" ? "stdiocommand" : "maincommand"};
    my (@tests) = find_tests($id, $type, $command);
    return undef if !@tests;

    # return error test if more than one error observed
    my (@errortests) = grep { exists($_->{"killed"}) } @tests;
    if (@errortests > 1) {
        $errortests[0]->{"medianof"} = scalar(@tests);
        $errortests[0]->{"stderr"} = "" if !exists($errortests[0]->{"stderr"});
        return $errortests[0];
    }

    # collect stderr and md5sum from all tests
    my ($stderr) = join("", map {
                            exists($_->{"stderr"}) ? $_->{"stderr"} : ""
                        } @tests);
    my (%md5sums) = map {
        exists($_->{"md5sum"}) ? ($_->{"md5sum"} => 1) : ()
    } @tests;
    my (%outputsizes) = map {
        exists($_->{"outputsize"}) ? ($_->{"outputsize"} => 1) : ()
    } @tests;

    # pick median test (or another test that's not erroneous)
    @tests = sort { $a->{"time"} <=> $b->{"time"} } @tests;
    my($tt) = {};
    my($tidx) = int(@tests / 2);
    for (my $j = 0; $j < @tests; ++$j) {
        %$tt = %{$tests[$tidx]};
        last if !exists($tt->{"killed"}) && !exists($tt->{"different_size"})
            && !exists($tt->{"different_content"});
        $tidx = ($tidx + 1) % @tests;
    }

    # decorate it
    $tt->{"medianof"} = scalar(@tests);
    $tt->{"stderr"} = $stderr;
    if (keys(%md5sums) == 1) {
        $tt->{"md5sum"} = (keys(%md5sums))[0];
    }
    if (keys(%outputsizes) > 1 || keys(%md5sums) > 1) {
        $tt->{"stderr"} .= "    ${Red}ERROR: trial runs generated different output${Off}\n";
    }
    return $tt;
}

sub print_stdio ($) {
    my($t) = @_;
    my($maxrss) = defined($t->{"maxrss"}) ? $t->{"maxrss"} : 0;
    if (exists($t->{"utime"})) {
        printf("%.5fs (%.5fs user, %.5fs system, %.0fMiB memory, %d trial%s)\n",
               $t->{"time"}, $t->{"utime"}, $t->{"stime"}, $maxrss / 1024.0,
               $t->{"medianof"}, $t->{"medianof"} == 1 ? "" : "s");
    } else {
        printf("${Red}KILLED${Redctx} after %.5fs (%d trial%s)${Off}\n",
               $t->{"time"},
               $t->{"medianof"}, $t->{"medianof"} == 1 ? "" : "s");
    }
}

sub check_trial_errors ($$) {
    my($tt, $qitem) = @_;
    my($error) = 0;
    if (exists($tt->{"different_size"})) {
        my($size) = defined($tt->{"outputsize"}) ? $tt->{"outputsize"} : 0;
        print "    ${Red}ERROR: ", join("+", @{$qitem->{"outfiles"}}), " has size ", $size, ", expected ", $tt->{"different_size"}, "${Off}\n";
        $error = 1;
    }
    if (exists($tt->{"different_content"})) {
        print "    ${Red}ERROR: ", $tt->{"different_content"}, "$Off\n";
        print "       ${Redctx}", $tt->{"different_content_context"}, "$Off\n"
            if $tt->{"different_content_context"};
        $error = 1;
    }
    $error;
}

sub run () {
    @workq = shuffle(@workq) if !$SEQTEST;
    my ($id, $type) = ("", undef);
    my $stdiot;

    if ($param{"MAKEFIRST"}) {
        foreach my $qitem (@workq) {
            add_make_targets($qitem->{"command"});
        }
        maybe_make("");
    }

    for (my $qpos = 0; $qpos < @workq; $qpos += 1) {
        my ($qitem) = $workq[$qpos];

        # maybe skip if a stdio trial remains to be done
        if ($qitem->{"type"} eq "yourcode"
            && $qitem->{"has_stdio"}
            && $qitem->{"compare"}
            && !$qitem->{"expect"}
            && !first_trial($qitem->{"id"}, "stdio", $qitem)
            && $qpos < @workq - 1) {
            my $qrpos = int(rand(@workq - ($qpos + 1))) + $qpos + 1;
            $workq[$qpos] = $workq[$qrpos];
            $workq[$qrpos] = $qitem;
            $qpos -= 1;
            next;
        }

        # print header
        my $print_command = !$param{"NOCOMMAND"}
            && ($qitem->{"id"} !~ /^SECRET/ || $param{"ALLCOMMAND"});
        if ($id ne $qitem->{"id"}
            || !$SEQTEST) {
            $id = $qitem->{"id"};
            print $SEQTEST ? $Cyan : $Cyanctx, "Test ", $id, ": ", $qitem->{"desc"}, "$Off\n";
            my $cmd = $qitem->{"maincommand"};
            $cmd =~ s/\b(inputs|outputs|stdoutputs)\//${ROOT}$1\//g if $ROOT ne "";
            print "COMMAND:   ", $cmd, "\n" if $print_command;
            $type = "";
            $stdiot = undef;
        }
        if (($type ne $qitem->{"type"})
            && $SEQTEST
            && $qitem->{"type"} eq "yourcode"
            && ($stdiot = median_trial($id, "stdio", $qitem))) {
            print "STDIO:     " if $param{"NOSTDIO"};
            print_stdio($stdiot);
        }
        maybe_make($qitem->{"command"});
        if ($qitem->{"check_random"}) {
            maybe_make("./randcheck61");
        }
        if ($type ne $qitem->{"type"}) {
            print "STRACE COMMAND:\n           ", $qitem->{"command"}, "\n"
                if $print_command && $param{"STRACE"};
            $type = $qitem->{"type"};
            print ($type eq "stdio" ? "STDIO:     " : "YOUR CODE: ");
        }

        # run it
        my ($t) = run_qitem($qitem);

        # compare results
        if (!exists($t->{"killed"})
            && $qitem->{"type"} eq "yourcode") {
            my $stdiott = $stdiot ? $stdiot : first_trial($id, "stdio", $qitem);
            check_trial_output($t, $stdiott, $qitem);
        }

        # print messages about trial
        if (!$SEQTEST && !$t) {
            $qitem_last_error = "previous trials too slow or had errors" if !$qitem_last_error;
            printf("${Redctx}trial skipped (${qitem_last_error})${Off}\n");
        } elsif (!$SEQTEST) {
            if (exists($t->{"killed"})) {
                printf("${Red}KILLED${Redctx} (%s) after %.5fs${Off}\n",
                       $t->{"killed"}, $t->{"time"});
            } else {
                printf("%.5fs (%.5fs user, %.5fs system, %.0fMiB memory)\n",
                   $t->{"time"}, $t->{"utime"}, $t->{"stime"}, $t->{"maxrss"} / 1024.0);
            }
            check_trial_errors($t, $qitem);
            print $t->{"stderr"}, "\n" if exists($t->{"stderr"}) && $t->{"stderr"} ne "";
        }

        if ($command_trials{$qitem->{"maincommand"}}) {
            next;
        }

        # print results
        if (!$SEQTEST) {
            print "\n${Cyan}TEST $id SUMMARY: ", $qitem->{"desc"}, "$Off\n";
            if (($stdiot = median_trial($id, "stdio", $qitem))) {
                print "STDIO:     ";
                print_stdio($stdiot);
            }
            print "YOUR CODE: ";
        }

        my $tt = median_trial($id, "yourcode", $qitem);
        print "YOUR CODE: " if $tt && $param{"NOYOURCODE"};
        if ($tt && exists($tt->{"killed"})) {
            printf "${Red}KILLED${Redctx} (%s)${Off}\n", $tt->{"killed"};
            ++$nkilled;
        } elsif ($tt) {
            printf("%.5fs (%.5fs user, %.5fs system, %.0fMiB memory, %d trial%s)\n",
               $tt->{"time"}, $tt->{"utime"}, $tt->{"stime"}, $tt->{"maxrss"} / 1024.0,
               $tt->{"medianof"}, $tt->{"medianof"} == 1 ? "" : "s");
            push @runtimes, $tt->{"time"};
        }

        # print stdio vs. yourcode comparison
        if ($stdiot
            && $tt
            && $tt->{"time"}
            && !exists($tt->{"killed"})
            && !exists($tt->{"different_size"})
            && !exists($tt->{"different_content"})
            && $qitem->{"perf"}) {
            my ($ratio) = $stdiot->{"time"} / $tt->{"time"};
            my ($color);
            if ($ratio < 0.75) {
                $color = $Redctx;
            } elsif ($ratio < 1.9) {
                $color = $Cyan;
            } else {
                $color = $Green;
            }
            printf("RATIO:     ${color}%.2fx stdio${Off}\n", $ratio);
            push @ratios, $ratio;
            push @basetimes, $stdiot->{"time"};
        }
        if ($tt && !exists($tt->{"killed"})) {
            if (check_trial_errors($tt, $qitem)) {
                ++$nerror;
            } elsif (!$qitem->{"perf"}) {
                print STDERR "${Green}Test ", $qitem->{"id"}, " PASSED$Off\n";
            }
        }

        # print yourcode stderr and a blank-line separator
        print $tt->{"stderr"} if exists($tt->{"stderr"}) && $tt->{"stderr"} ne "";
        print "\n";
    }
}

sub pl ($$) {
    my ($n, $x) = @_;
    return $n . " " . ($n == 1 ? $x : $x . "s");
}

sub summary () {
    my ($ntests) = @runtimes + $nkilled;
    print "SUMMARY:   ", pl($ntests, "test"), ", ";
    if ($nkilled) {
        print "${Red}$nkilled killed,${Off} ";
    } else {
        print "0 killed, ";
    }
    if ($nerror) {
        print "${Red}", pl($nerror, "error"), "${Off}\n";
    } else {
        print "0 errors\n";
    }
    my ($better) = scalar(grep { $_ > 1 } @ratios);
    my ($worse) = scalar(grep { $_ < 1 } @ratios);
    if ($better || $worse) {
        print "           better than stdio ", pl($better, "time"),
        ", worse ", pl($worse, "time"), "\n";
    }
    my ($mean, $basetime, $runtime) = (0, 0, 0);
    for (my $i = 0; $i < @ratios; ++$i) {
        $mean += $ratios[$i];
        $basetime += $basetimes[$i];
    }
    for (my $i = 0; $i < @runtimes; ++$i) {
        $runtime += $runtimes[$i];
    }
    if (@ratios) {
        printf "           average %.2fx stdio\n", $mean / @ratios;
        printf "           total time %.3fs stdio, %.3fs your code (%.2fx stdio)\n",
        $basetime, $runtime, $basetime / $runtime;
    } elsif (@runtimes) {
        printf "           total time %.3f your code\n", $runtime;
    }

    if ($VERBOSE || $param{"MAKETRIALLOG"}) {
        my (@testjsons);
        foreach my $t (@alltests) {
            my (@tout, $k, $v) = ();
            while (($k, $v) = each %$t) {
                push @tout, "\"$k\":" . (looks_like_number($v) ? $v : "\"$v\"");
            }
            push @testjsons, "{" . join(",", @tout) . "}\n";
        }
        print "\n", @testjsons if $VERBOSE;
        if ($param{"MAKETRIALLOG"}) {
            open(OTRIALLOG, ">", $param{"MAKETRIALLOG"} eq "1" ? "triallog.txt" : $param{"MAKETRIALLOG"}) or die;
            print OTRIALLOG @testjsons;
            close(OTRIALLOG);
        }
    }
}

# read arguments and environment variables
%param = (
    "NOSTDIO" => boolenv("NOSTDIO"),
    "NOYOURCODE" => boolenv("NOYOURCODE"),
    "NOCOMMAND" => boolenv("NOCOMMAND"),
    "ALLCOMMAND" => boolenv("ALLCOMMAND"),
    "TRIALTIME" => nonemptyenv("TRIALTIME") ? $ENV{"TRIALTIME"} + 0 : 3,
    "STDIOTRIALTIME" => nonemptyenv("STDIOTRIALTIME") ? $ENV{"STDIOTRIALTIME"} + 0 : undef,
    "TRIALS" => nonemptyenv("TRIALS") ? int($ENV{"TRIALS"}) : 5,
    "STDIOTRIALS" => nonemptyenv("STDIOTRIALS") ? int($ENV{"STDIOTRIALS"}) : undef,
    "MAXTIME" => nonemptyenv("MAXTIME") ? $ENV{"MAXTIME"} + 0 : 20,
    "DEFS" => nonemptyenv("DEFS") ? $ENV{"DEFS"} : undef,
    "O" => nonemptyenv("O") ? $ENV{"O"} : undef,
    "SAN" => nonemptyenv("SAN") ? boolenv("SAN") : undef,
    "NDEBUG" => boolenv("NDEBUG"),
    "MAKEFIRST" => boolenv("MAKEFIRST"),
    "MAKESILENT" => boolenv("MAKESILENT"),
    "NOMAKE" => boolenv("NOMAKE"),
    "STRACE" => boolenv("STRACE"),
    "TMP" => nonemptyenv("TMP") ? boolenv("TMP") : undef
);

while (@ARGV) {
    if ($ARGV[0] eq "-r") {
        $SEQTEST = 0;
    } elsif ($ARGV[0] eq "-V") {
        $VERBOSE = 1;
    } elsif ($ARGV[0] =~ /\A([A-Z]+)=(\d*)\z/) {
        $param{$1} = $2 eq "" ? 0 : int($2);
    } elsif ($ARGV[0] =~ /\A([A-Z]+)=(.*)\z/s) {
        $param{$1} = $2;
    } else {
        push @ALLOW_TESTS, "XXXXX" if !@ALLOW_TESTS;
        foreach my $t (split_testmatch($ARGV[0])) {
            push @ALLOW_TESTS, $t;
        }
    }
    shift @ARGV;
}

$param{"TRIALS"} = 5 if $param{"TRIALS"} <= 0;
$param{"STDIOTRIALS"} = $param{"TRIALS"} if !defined($param{"STDIOTRIALS"});
$param{"STDIOTRIALS"} = 5 if $param{"STDIOTRIALS"} <= 0;
$param{"STDIOTRIALTIME"} = $param{"TRIALTIME"} if !defined($param{"STDIOTRIALTIME"});
$param{"MAXTIME"} = 20 if $param{"MAXTIME"} <= 0;
$param{"NOSTDIO"} = 1 if $param{"STRACE"};
$param{"DOCKER"} = -e "/usr/bin/cs61-docker-version" ? 1 : 0 if !defined($param{"DOCKER"});
$param{"TMP"} = $param{"DOCKER"} if !defined($param{"TMP"});

# maybe read a trial log
if (defined($param{"TRIALLOG"})) {
    read_triallog($param{"TRIALLOG"});
}

# maybe create a .cs61tmpid and a temporary directory
if (defined($param{"ROOT"})) {
    if ($param{"ROOT"} eq "" || !-d $param{"ROOT"}) {
        print STDERR "*** ROOT parameter is not a directory.\n";
        exit(1);
    }
    $ROOT = $param{"ROOT"};
} elsif ($param{"TMP"}) {
    my ($tmpid) = "";
    if (open my $fh, "<", ".cs61tmpid") {
        local $/;
        $tmpid = <$fh>;
        $tmpid =~ s/\n+\z//;
        close $fh;
    }
    if (!defined($tmpid) || $tmpid eq "") {
        my $want_bytes = $param{"DOCKER"} ? 2 : 8;
        if (open my $fh, "< :raw :bytes", "/dev/urandom") {
            my $txt = "";
            read $fh, $txt, $want_bytes;
            $tmpid = "cs61-" . unpack("h*", $txt);
            close $fh;
        }
        if (length($tmpid) < $want_bytes * 2) {
            print STDERR "*** Internal error: Cannot create \`.cs61tmpid\`.\n";
            exit(1);
        }
        if (open my $fh, ">", ".cs61tmpid") {
            print $fh $tmpid, "\n";
            close $fh;
        } else {
            print STDERR "*** Internal error: Cannot save \`.cs61tmpid\`.\n";
            exit(1);
        }
    }
    if ($tmpid !~ /\A[-A-Za-z0-9_]{1,40}\z/) {
        print STDERR "*** Invalid \`.cs61tmpid\`; remove it and try again.\n";
        exit(1);
    }
    my ($tmpdir) = $ENV{"TMPDIR"};
    $tmpdir = "/tmp" if !$tmpdir;
    $tmpdir =~ s/\/\z//;
    die "*** \`${tmpdir}\` is not a directory.\n" if !-d $tmpdir;
    $ROOT = $tmpdir . "/" . $tmpid;
    die "*** Cannot create \`${ROOT}\` directory.\n" if !-d $ROOT && (-e $ROOT || !mkdir($ROOT));
    $ROOT .= "/";
}

# create some files
foreach my $d ("inputs", "outputs", "stdoutputs") {
    die "*** Cannot create \`${ROOT}$d\` directory.\n"
        if !-d "${ROOT}$d" && (-e "${ROOT}$d" || !mkdir("${ROOT}$d"));
}

sub register_file ($$) {
    my ($fname, $offset) = @_;
    if ($fname !~ /\Ainputs\/(text|binary)(\d+[mkg])(|-rev)(\.txt|\.bin)\z/) {
        die "*** $fname: invalid filename\n";
    }
    my ($typestr, $szstr, $revstr, $extstr) = ($1, $2, $3, $4);
    die ("*** $fname: invalid filename\n") if ($typestr eq "text") != ($extstr eq ".txt");
    my ($sz) = +substr($szstr, 0, -1) * 1024;
    $sz *= 1024 if substr($szstr, -1) ne "k";
    $sz *= 1024 if substr($szstr, -1) eq "g";
    $fileinfo{$fname} = [0, 0, $sz, $offset];
    return $fname;
}

my ($textweeny) = register_file("inputs/text4k.txt", 0);
my ($texttiny) = register_file("inputs/text32k.txt", 0);
my ($bintiny) = register_file("inputs/binary32k.bin", 1 << 9);
my ($textsm) = register_file("inputs/text90k.txt", 2 << 9);
my ($revtextsm) = register_file("inputs/text90k-rev.txt", 3 << 9);
my ($binsm) = register_file("inputs/binary40k.bin", 4 << 9);
my ($binmd) = register_file("inputs/binary5m.bin", 4 << 9);
my ($textmd) = register_file("inputs/text10m.txt", 5 << 9);
my ($textlg) = register_file("inputs/text64m.txt", 6 << 9);

$SIG{"INT"} = sub {
    kill 9, -$run61_pid if $run61_pid;
    print STDERR "\n";
    summary();
    exit(1);
};


# SEQUENTIAL CORRECTNESS
enqueue("C1",
    "./cat61 -o outputs/out.txt $texttiny",
    "byte I/O, sequential correctness",
    "perf" => 0, "expect" => $texttiny);

enqueue("C2",
    "./cat61 -o outputs/out.txt $bintiny",
    "binary, byte I/O, sequential correctness",
    "perf" => 0, "expect" => $bintiny);

enqueue("C3",
    "./blockread61 -b 1024 -o outputs/out.txt $texttiny",
    "1KiB block I/O, sequential correctness",
    "perf" => 0, "expect" => $texttiny);

enqueue("C4",
    "./blockwrite61 -b 1024 -o outputs/out.txt $texttiny",
    "1KiB block I/O, sequential correctness",
    "perf" => 0, "expect" => $texttiny);

enqueue("C5",
    "./blockcat61 -b 1024 -o outputs/out.txt $texttiny",
    "1KiB block I/O, sequential correctness",
    "perf" => 0, "expect" => $texttiny);

enqueue("C6",
    "./blockread61 -b 1021 -o outputs/out.txt $texttiny",
    "1021B block I/O, sequential correctness",
    "perf" => 0, "expect" => $texttiny);

enqueue("C7",
    "./blockwrite61 -b 1021 -o outputs/out.txt $texttiny",
    "1021B block I/O, sequential correctness",
    "perf" => 0, "expect" => $texttiny);

enqueue("C8",
    "cat $texttiny | ./cat61 | cat > outputs/out.txt",
    "byte I/O, piped, sequential correctness",
    "perf" => 0, "expect" => $texttiny);

enqueue("C9",
    "cat $texttiny | ./blockcat61 -b 1024 | cat > outputs/out.txt",
    "1KiB block I/O, piped, sequential correctness",
    "perf" => 0, "expect" => $texttiny);

enqueue("C10",
    "cat $texttiny | ./blockcat61 -b 1021 | cat > outputs/out.txt",
    "1021B block I/O, piped, sequential correctness",
    "perf" => 0, "expect" => $texttiny);

enqueue("C11",
    "./carefulcat61 -a 0.001 $textsm | ./syscall-carefulblockcat61 -D 0.002 -b 117 -y > outputs/out.txt",
    "byte I/O, short-piped, sequential correctness",
    "perf" => 0, "expect" => $textsm);

enqueue("C12",
    "./randblockcat61 -b 256 -o outputs/out.txt $texttiny",
    "random block I/O, sequential correctness",
    "perf" => 0, "expect" => $texttiny);

enqueue("C13",
    "./randblockcat61 -b 256 -X -o outputs/out.txt $texttiny",
    "random block I/O, sequential correctness",
    "perf" => 0, "expect" => $texttiny);

enqueue("C14",
    "./scattergather61 -b 512 -o outputs/c17.bin $binsm $textsm",
    "gathered small files, 512B block I/O, sequential",
    "perf" => 0, "compare" => 1);

enqueue("C15",
    "./scattergather61 -b 512 -o outputs/c18a.txt -o outputs/c18b.txt -o outputs/c18c.txt < $textsm",
    "scattered small file, 512B block I/O, sequential",
    "perf" => 0, "compare" => 1);

enqueue("C16",
    "./scattergather61 -b 509 -o outputs/c19a.txt -o outputs/c19b.txt -o outputs/c19c.txt -o outputs/c19d.txt -i $textsm -i $revtextsm -i $textsm",
    "scatter/gather 4/3 files, 509B block I/O, sequential",
    "perf" => 0, "compare" => 1);

enqueue("C17",
    "./scattergather61 -b 128 -l -o outputs/c20a.txt -o outputs/c20b.txt -o outputs/c20c.txt -o outputs/c20d.txt -i $textsm -i $revtextsm -i $textsm",
    "scatter/gather 4/3 files by lines, byte I/O, sequential",
    "perf" => 0, "compare" => 1);

enqueue("C18",
    "./cat61 -s 4096 -o outputs/c21.txt /dev/urandom",
    "unmappable file, byte I/O, sequential",
    "perf" => 0, "compare" => -1, "insize" => 4096);

enqueue("C19",
    "./reverse61 -s 500000 -o outputs/out.txt /dev/zero",
    "magic zero file, byte I/O, sequential",
    "perf" => 0, "insize" => 500000);

enqueue("C20",
    "./reverse61 -s 400000 -o outputs/out.txt /dev/urandom",
    "magic random file, byte I/O, sequential",
    "perf" => 0, "compare" => -1, "insize" => 400000, "check_random" => 1);


# NONSEQUENTIAL CORRECTNESS
enqueue("CN1",
    "cp $texttiny outputs/c12.txt; ./cat61 -s 1992 $texttiny | ./writeat61 -o outputs/c12.txt -p 8188",
    "byte I/O, seek correctness",
    "perf" => 0, "compare" => 1);

enqueue("CN2",
    "./reverse61 $texttiny > outputs/c13.txt",
    "byte I/O, correctness for reverse reads",
    "perf" => 0, "compare" => 1);

enqueue("CN3",
    "./wreverse61 $texttiny > outputs/c14.txt",
    "byte I/O, correctness for reverse writes",
    "perf" => 0, "compare" => 1);

enqueue("CN4",
    "./stridecat61 -b 3 -s 10 $texttiny > outputs/c15.txt",
    "byte I/O, correctness for strided reads",
    "perf" => 0, "compare" => 1);

enqueue("CN5",
    "./wstridecat61 -b 8 -s 128 $texttiny > outputs/c16.txt",
    "byte I/O, correctness for strided writes",
    "perf" => 0, "compare" => 1);

enqueue("CN6",
    "./reverse61 -q -s 4096 -o outputs/c22.txt /dev/urandom",
    "unmappable file, byte I/O, reverse order",
    "perf" => 0, "compare" => -1, "insize" => 4096);

enqueue("CN7",
    "./reverse61 -s 500000 -o outputs/out.txt /dev/urandom",
    "magic random file, byte I/O, reverse order",
    "perf" => 0, "compare" => -1, "insize" => 500000, "check_random" => 1);


# REGULAR FILES, SEQUENTIAL I/O
enqueue("MP1",
    "./blockcat61 -b 1024 -o outputs/out.txt $textmd",
    "regular medium file, 1KB block I/O, sequential");

enqueue("MP2",
    "./blockcat61 -b 8192 -o outputs/out.txt $textmd",
    "regular medium file, 8KB block I/O, sequential");

enqueue("MP3",
    "./blockcat61 -R -b 8192 -o outputs/out.txt $textmd",
    "regular medium file, byte reads/8KB block writes, sequential");

enqueue("MP4",
    "./cat61 -o outputs/out.txt $textmd",
    "regular medium file, byte I/O, sequential");

enqueue("MP5",
    "./blockcat61 -o outputs/out.bin $binmd",
    "regular medium binary file, 4KB block I/O, sequential");

enqueue("MP6",
    "./blockcat61 -b 509 -o outputs/out.txt $textmd",
    "regular medium file, 509B block I/O, sequential");

enqueue("MP7",
    "./cat61 -s 5242880 -o outputs/out.txt /dev/zero",
    "magic file, byte I/O, sequential",
    "insize" => 5242880);

enqueue("MP8",
    "cat $textmd | ./blockcat61 -b 1024 | cat > outputs/out.txt",
    "piped medium file, 1KB block I/O, sequential");

enqueue("MP9",
    "./blockcat61 -b 1024 $textmd | cat > outputs/out.txt",
    "mixed-piped medium file, 1KB block I/O, sequential");


# NONSEQUENTIAL
enqueue("MPN1",
    "./reverse61 -o outputs/out.txt $textmd",
    "regular medium file, byte I/O, reverse order");

enqueue("MPN2",
    "./reverse61 -s 5242880 -o outputs/out.txt /dev/zero",
    "magic file, byte I/O, reverse order",
    "insize" => 5242880);

enqueue("MPN3",
    "./stridecat61 -t 1048576 -o outputs/out.txt $textmd",
    "regular medium file, byte I/O, 1MB stride order");

enqueue("MPN4",
    "./stridecat61 -t 2 -o outputs/out.txt $textmd",
    "regular medium file, byte I/O, 2B stride order");


# LARGE FILES
enqueue("LP1",
    "./cat61 -o outputs/out.txt $textlg",
    "regular large file, byte I/O, sequential");

enqueue("LP2",
    "./blockcat61 -o outputs/out.txt $textlg",
    "regular large file, 4KB block I/O, sequential");

enqueue("LP3",
    "./randblockcat61 -o outputs/out.txt $textlg",
    "regular large file, 1B-4KB block I/O, sequential");

enqueue("LP4",
    "./randblockcat61 -r 6582 -o outputs/out.txt $textlg",
    "regular large file, 1B-4KB block I/O, sequential");

enqueue("LP5",
    "cat $textlg | ./cat61 | cat > outputs/out.txt",
    "piped large file, byte I/O, sequential");

enqueue("LP6",
    "cat $textlg | ./blockcat61 | cat > outputs/out.txt",
    "piped large file, 4KB block I/O, sequential");

enqueue("LP7",
    "cat $textlg | ./randblockcat61 | cat > outputs/out.txt",
    "piped large file, 1B-4KB block I/O, sequential");

enqueue("LP8",
    "cat $textlg | ./blockcat61 -o outputs/out.txt",
    "mixed-piped large file, 4KB block I/O, sequential");

enqueue("LP9",
    "./randblockcat61 $textlg > outputs/out.txt",
    "redirected large file, 1B-4KB block I/O, sequential");

enqueue("LPN1",
    "./reverse61 -s 8388608 -o outputs/out.txt $textlg",
    "regular large file, byte I/O, reverse order");

enqueue("LPN2",
    "./reordercat61 -o outputs/out.txt $textlg",
    "regular large file, 4KB block I/O, random seek order");

enqueue("LPN3",
    "./reordercat61 -r 6582 -o outputs/out.txt $textlg",
    "regular large file, 4KB block I/O, random seek order");


run();

summary();
