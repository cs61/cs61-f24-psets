#! /usr/bin/perl -w

# check.pl
#    This program runs tests on breakout61 and analyzes the results
#    for errors.

use Time::HiRes qw(gettimeofday);
use Fcntl qw(F_GETFL F_SETFL O_NONBLOCK);
use POSIX;
use Scalar::Util qw(looks_like_number);
use List::Util qw(shuffle min max);
use Config;

sub first (@) { return $_[0]; }
my($TTY) = (`tty` or "/dev/tty");
chomp($TTY);
my(@sig_name) = split(/ /, $Config{"sig_name"});
my($SIGINT) = 0;
while ($sig_name[$SIGINT] ne "INT") {
    ++$SIGINT;
}

my($Red, $Redctx, $Green, $Greenctx, $Cyan, $Ylo, $Yloctx, $Off) = ("\x1b[01;31m", "\x1b[0;31m", "\x1b[01;32m", "\x1b[0;32m", "\x1b[01;36m", "\x1b[01;33m", "\x1b[0;33m", "\x1b[0m");
$Red = $Redctx = $Green = $Greenctx = $Cyan = $Ylo = $Yloctx = $Off = "" if !-t STDERR || !-t STDOUT;

my(@clean_pgrps);
sub remove_clean_pgrp ($) {
    my $i = 0;
    ++$i while ($i < @clean_pgrps && $clean_pgrps[$i] != $_[0]);
    splice(@clean_pgrps, $i, 1) if $i < @clean_pgrps;
}
sub kill_clean_pgrp () {
    foreach my $pgrp (@clean_pgrps) {
        kill -9, $pgrp;
    }
    @clean_pgrps = ();
}

$SIG{"CHLD"} = sub {};
$SIG{"TSTP"} = "DEFAULT";
$SIG{"TTOU"} = "IGNORE";
$SIG{"INT"} = sub {
    kill_clean_pgrp();
    $SIG{"INT"} = "DEFAULT";
    kill $SIGINT, $$;
};
my($ignore_sigint) = 0;
open(TTY, "+<", $TTY) or die "can't open $TTY: $!";


my($ntest) = 0;
my($ntestfailed) = 0;

# check for a ton of existing breakout61 processes
$me = `id -un`;
chomp $me;
open(RUN61, "ps uxww | grep '^$me.*breakout61' | grep -v grep |");
$nrun61 = 0;
$nrun61 += 1 while (defined($_ = <RUN61>));
close RUN61;
if ($nrun61 > 5) {
    print STDERR "\n";
    print STDERR "${Red}**** Looks like $nrun61 ./breakout61 processes are already running.\n";
    print STDERR "**** Do you want all those processes?\n";
    print STDERR "**** Run 'killall -9 breakout61' to kill them.${Off}\n\n";
}

sub unparse_signal ($) {
    my($s) = @_;
    my(@sigs) = split(" ", $Config{sig_name});
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
    while ((!defined($size) || length($text) <= $size + 8192)
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
    pipe(OR, OW) or die "pipe";
    fcntl(OR, F_SETFL, fcntl(OR, F_GETFL, 0) | O_NONBLOCK);
    1 while waitpid(-1, WNOHANG) > 0;

    my($preutime, $prestime, $precutime, $precstime) = times();

    my($run61_pid) = fork();
    if ($run61_pid == 0) {
        $SIG{"INT"} = "DEFAULT";
        POSIX::setpgid(0, 0) or die("child setpgid: $!\n");
        POSIX::tcsetpgrp(fileno(TTY), $$) or die("child tcsetpgrp: $!\n");
        defined($dir) && chdir($dir);
        close(TTY); # for explicitness: Perl will close by default

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

        {
            if (ref $command) {
                exec { $command->[0] } @$command;
            } else {
                exec($command);
            }
        }
        print STDERR "error trying to run $command: $!\n";
        exit(1);
    }

    my($run61_pgrp) = $run61_pid;
    POSIX::setpgid($run61_pid, $run61_pgrp);    # might fail if child exits quickly
    POSIX::tcsetpgrp(fileno(TTY), $run61_pgrp); # might fail if child exits quickly
    push @clean_pgrps, $run61_pgrp;

    my($before) = Time::HiRes::time();
    my($died) = 0;
    my($time_limit) = exists($opt{"time_limit"}) ? $opt{"time_limit"} : 0;
    my($out, $buf, $nb) = ("", "");
    my($answer) = exists($opt{"answer"}) ? $opt{"answer"} : {};
    $answer->{"command"} = $command;
    my($sigint_at) = defined($opt{"int_delay"}) ? $before + $opt{"int_delay"} : undef;
    my($sigint_state) = defined($sigint_at) ? 1 : 0;

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
        } while (!$time_limit || Time::HiRes::time() < $before + $time_limit);
        if (waitpid($run61_pid, WNOHANG) > 0) {
            $answer->{"status"} = $?;
        } else {
            $died = sprintf("timeout after %.2fs", $time_limit);
        }
    };

    POSIX::tcsetpgrp(fileno(TTY), getpgrp()) or print STDERR "parent tcsetpgrp: $!\n";
    my($delta) = Time::HiRes::time() - $before;
    $answer->{"time"} = $delta;
    my($run61_status) = exists($answer->{"status"}) ? $answer->{"status"} : 0;

    if ($sigint_state < 2
        && ($run61_status & 127) == $SIGINT
        && !$ignore_sigint) {
        # assume user is trying to quit
        kill_clean_pgrp();
        exit(2);
    }
    if (exists($answer->{"status"})
        && exists($opt{"delay"})
        && $opt{"delay"} > 0) {
        Time::HiRes::usleep($opt{"delay"} * 1e6);
    }
    if (exists($opt{"nokill"})
        && $opt{"nokill"} > 0) {
        $answer->{"pgrp"} = $run61_pgrp;
    } else {
        kill -9, $run61_pgrp;
        waitpid($run61_pid, 0);
        remove_clean_pgrp($run61_pgrp);
    }

    my($postutime, $poststime, $postcutime, $postcstime) = times();
    $answer->{"utime"} = $postcutime - $precutime;
    $answer->{"stime"} = $postcstime - $precstime;

    if ($died) {
        $answer->{"killed"} = $died;
    }

    if (defined($outfile) && $outfile ne "pipe") {
        $out = "";
        close(OR);
        open(OR, "<", (defined($dir) ? "$dir/$outfile" : $outfile));
    }
    $out = run_sh61_pipe($out, fileno(OR), $size_limit);
    close(OR);
    $answer->{"output"} = $out;

    my(@stderr);
    if (exists($answer->{"status"})
        && ($answer->{"status"} & 127)
        && (($answer->{"status"} & 127) != $SIGINT || $sigint_state != 2)) {
        my($signame) = unparse_signal($answer->{"status"} & 127);
        if (exists($answer->{"trial"})) {
            push @stderr, "    ${Redctx}KILLED by $signame (trial " . $answer->{"trial"} . ")${Off}";
        } else {
            push @stderr, "    ${Redctx}KILLED by $signame${Off}";
        }
        if (($answer->{"status"} & 127) == $SIGINT) {
            kill $SIGINT, 0;
        }
    }
    $answer->{"stderr"} = join("\n", @stderr) if @stderr;

    return $answer;
}

open(OUT, ">&STDOUT");

print OUT "${Cyan}Building without sanitizers...${Off}\n";
system("make", "SAN=0", "breakout61");
my($tt);

# Deadlock check
print OUT "\n${Cyan}Deadlock check (should see many ball positions)...${Off}\n";
my($info) = run_sh61("./breakout61 -B0 -d0.01 -w13 -h8 -b6 -s4 -p0.05", "stdin" => "/dev/null", "stdout" => "pipe", "time_limit" => 0.6, "size_limit" => 20000);
if (!exists($info->{"killed"}) || $info->{"killed"} !~ /^timeout/) {
    print OUT "${Red}FAILURE${Redctx} (expected timeout, got ",
        (exists($info->{"killed"}) ? $info->{"killed"} : "exit status " . $info->{"status"}),
        ")${Off}\n";
}
my(@board) = (0) x (13 * 8);
my($ypos, $nrounds) = (0, 0);
foreach my $line (split(/\n/, $info->{"output"})) {
    $line =~ s/\x1b\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]//g;
    if ($line =~ /\A[A-Z._|]{13}\n?\z/) {
        for (my $x = 0; $x < 13; ++$x) {
            my $ch = substr($line, $x, 1);
            if ($ch ge "A" && $ch le "Z") {
                $board[$ypos + $x] = 0 if $board[$ypos + $x] eq "_";
                $board[$ypos + $x] += 1;
            } elsif ($ch eq "_") {
                $board[$ypos + $x] = "_" if $board[$ypos + $x] eq 0;
            }
        }
        $ypos += 13;
        if ($ypos == 13 * 8) {
            $ypos = 0;
            ++$nrounds;
        }
    } elsif ($line =~ /\S/ && $line !~ /^\d+ balls?.*collision/) {
        print OUT "${Redctx}  unexpected output: $line${Off}\n";
    }
}
my(@counts) = (0, 0, 0, 0);
for (my $y = 0; $y < 8; ++$y) {
    print OUT "  ";
    for (my $x = 0; $x < 13; ++$x) {
        my $ch = $board[$y * 13 + $x];
        $counts[$ch eq "_" ? 0 : $ch] += 1;
        $ch = "*" if $ch ne "_" && $ch > 9;
        $ch = "." if $ch eq 0;
        print OUT $ch;
    }
    print OUT "\n";
}
if ($nrounds < 5) {
    print OUT "${Red}ERROR:${Redctx} too few boards printed${Off} (", $counts[1], " unique ball positions)\n";
} elsif ($counts[1] + 2 * $counts[2] >= $nrounds * 2) {
    print OUT "${Green}PASS${Off} (", $counts[1], " unique ball positions)\n";
} else {
    print OUT "${Red}ERROR:${Redctx} too few unique ball positions${Off}\n";
    print OUT "  ${Redctx}$nrounds boards";
    for (my $p = 1; $p < @counts; ++$p) {
        if ($counts[$p]) {
            print OUT ", ", $p, " pos ", $counts[$p], "x";
        }
    }
    print OUT "${Off}\n";
}

# Polling check
print OUT "\n${Cyan}Polling check...${Off}\n";
$info = run_sh61("./breakout61 -B0 -d0.01 -w26 -h16 -b10 -s20 -p0", "stdin" => "/dev/null", "stdout" => "pipe", "time_limit" => 1, "size_limit" => 20000);
if (!exists($info->{"killed"}) || $info->{"killed"} !~ /^timeout/) {
    print OUT "${Red}FAILURE${Redctx} (expected timeout, got ",
        (exists($info->{"killed"}) ? $info->{"killed"} : "exit status " . $info->{"status"}),
        ")${Off}\n";
}
$tt = sprintf("(%.3fs real, %.3fs/%.0f%% user)", $info->{"time"}, $info->{"utime"}, 100 * $info->{"utime"} / $info->{"time"});
if ($info->{"utime"} > $info->{"time"} * 0.8) {
    print OUT "${Red}ERROR:${Redctx} too much user time $tt${Off}\n";
} elsif ($info->{"utime"} > $info->{"time"} * 0.2) {
    print OUT "${Ylo}WARNING:${Yloctx} too much user time $tt${Off}\n";
} elsif (exists($info->{"killed"}) && $info->{"killed"} =~ /^timeout/) {
    print OUT "${Green}PASS${Off} $tt\n";
}

# Polling check with warps
print OUT "\n${Cyan}Polling check with warps...${Off}\n";
$info = run_sh61("./breakout61 -B0 -d0.01 -w26 -h16 -b10 -s10 -W10 -p0", "stdin" => "/dev/null", "stdout" => "pipe", "time_limit" => 1, "size_limit" => 20000);
if (!exists($info->{"killed"}) || $info->{"killed"} !~ /^timeout/) {
    print OUT "${Red}FAILURE${Redctx} (expected timeout, got ",
        (exists($info->{"killed"}) ? $info->{"killed"} : "exit status " . $info->{"status"}),
        ")${Off}\n";
}
$tt = sprintf("(%.3fs real, %.3fs/%.0f%% user)", $info->{"time"}, $info->{"utime"}, 100 * $info->{"utime"} / $info->{"time"});
if ($info->{"utime"} > $info->{"time"} * 0.8) {
    print OUT "${Red}ERROR:${Redctx} too much user time $tt${Off}\n";
} elsif ($info->{"utime"} > $info->{"time"} * 0.2) {
    print OUT "${Ylo}WARNING:${Yloctx} too much user time $tt${Off}\n";
} elsif (exists($info->{"killed"}) && $info->{"killed"} =~ /^timeout/) {
    print OUT "${Green}PASS${Off} $tt\n";
}

# Sanitizer run
print OUT "\n${Cyan}Building with sanitizers...${Off}\n";
system("make SAN=1 breakout61 >/dev/null");
$ENV{"TSAN_OPTIONS"} = "color=always";
print OUT "${Cyan}Sanitizer check (should see no sanitizer messages)...${Off}\n";
$info = run_sh61("./breakout61 -p0", "stdin" => "/dev/null", "stdout" => "pipe", "time_limit" => 3, "size_limit" => 20000);
if (!exists($info->{"killed"}) || $info->{"killed"} !~ /^timeout/) {
    print OUT "${Red}FAILURE${Redctx} (expected timeout, got ",
        (exists($info->{"killed"}) ? $info->{"killed"} : "exit status " . $info->{"status"}),
        ")${Off}\n";
}
$info->{"output"} =~ s/\x1b\[\?\d*h//g;
if ($info->{"output"} =~ /\S/) {
    $info->{"output"} .= "…\n" if $info->{"output"} !~ /\n\z/;
    print OUT "${Red}ERROR:${Off}\n", $info->{"output"};
} elsif (exists($info->{"killed"}) && $info->{"killed"} =~ /^timeout/) {
    print OUT "${Green}PASS${Off}\n";
}

# Sanitizer run with warps
print OUT "\n${Cyan}Sanitizer check with warps (should see no sanitizer messages)...${Off}\n";
$info = run_sh61("./breakout61 -W10 -p0", "stdin" => "/dev/null", "stdout" => "pipe", "time_limit" => 3, "size_limit" => 20000);
if (!exists($info->{"killed"}) || $info->{"killed"} !~ /^timeout/) {
    print OUT "${Red}FAILURE${Redctx} (expected timeout, got ",
        (exists($info->{"killed"}) ? $info->{"killed"} : "exit status " . $info->{"status"}),
        ")${Off}\n";
}
$info->{"output"} =~ s/\x1b\[\?\d*h//g;
if ($info->{"output"} =~ /\S/) {
    $info->{"output"} .= "…\n" if $info->{"output"} !~ /\n\z/;
    print OUT "${Red}ERROR:${Off}\n", $info->{"output"};
} elsif (exists($info->{"killed"}) && $info->{"killed"} =~ /^timeout/) {
    print OUT "${Green}PASS${Off}\n";
}

exit(0);
