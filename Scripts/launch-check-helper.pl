#!/usr/bin/perl
# launch-check.sh's helper (0.9.4). Three commands:
#
#   running BIN_ABS BIN_PHYS
#       Prints "pid path" for every running Tankard that shares this user's
#       cache folder: this app (either spelling of its path), and any other
#       build of it (any …/Contents/MacOS/Tankard, or a `swift run` one,
#       …/TankardApp), since every build reads
#       and writes the same ~/Library/Caches/net.mindtricks.tankard. A
#       process of another (non-root) user has its own cache and is left
#       out; so is one of this user whose HOME is visibly another one while
#       ours is not the account's own (a test's throwaway HOME, say). When
#       its HOME can't be read it counts. A path that only starts like
#       Tankard's (Build1app/…/Tankard-helper) is not Tankard.
#
#   mkcache DIR
#       Makes DIR, which must not exist, as one step that nothing can slip
#       into: a private (0700) folder next to it is made and opened
#       (O_NOFOLLOW), its device:inode taken from the open handle, then it
#       is renamed to DIR with renameatx_np(RENAME_EXCL), which fails if
#       anything (a folder, a link, a file) is at DIR by then. DIR must then
#       be that same folder, still empty; it gets the usual mode (0777 less
#       the umask, as the app's own mkdir) through the handle. Prints
#       device:inode. Exit 1, with the reason on stderr, otherwise (and
#       then DIR, if something else is there, is left alone).
#
#   supervise RESULT STOPFILE SECONDS LOG -- COMMAND...
#       Launches COMMAND (stdout and stderr to LOG) as this process's child,
#       and is the only one that ever signals it. The child is reaped
#       (waitpid) only once nothing more will be sent to it: until then its
#       pid stays reserved, even if it has exited (a zombie), so neither the
#       Quit nor SIGTERM/SIGKILL can reach a reused pid. Once a WNOHANG
#       waitpid reports it gone, nothing is sent to it again.
#       It must stay up SECONDS; then it gets the Quit (osascript, bounded:
#       an alarm at 10s and SIGKILL at 12s, so a stalled osascript can't
#       hold the check), 5s to exit, SIGTERM, 5s more, SIGKILL.
#       RESULT gets "pid N" at launch, then one of
#         exited RC            it exited by itself within SECONDS
#         stopped HOW RC       quit, TERM or KILL ended it
#         aborted              STOPFILE appeared, this process got
#                              SIGTERM/SIGHUP, or its parent died: the
#                              child was SIGKILLed and reaped
#       RC is the exit status, or 128 + the signal, as in bash.
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_DIRECTORY O_NOFOLLOW);
use POSIX qw(WNOHANG WIFEXITED WEXITSTATUS WIFSIGNALED WTERMSIG _exit);
use Time::HiRes qw(sleep time);
use Cwd qw(abs_path);

my $cmd = shift @ARGV // '';
if ($cmd eq 'running') { running(@ARGV) }
elsif ($cmd eq 'mkcache') { exit mkcache(@ARGV) }
elsif ($cmd eq 'supervise') { exit supervise(@ARGV) }
else { die "launch-check-helper.pl: unknown command '$cmd'\n" }

sub same_path {
    my ($x, $y) = @_;
    return 0 unless defined $x && defined $y;
    return 1 if $x eq $y;
    my ($ra, $rb) = (abs_path($x), abs_path($y));
    return defined $ra && defined $rb && $ra eq $rb;
}

sub running {
    my ($abs, $phys) = @_;
    my $home = $ENV{HOME} // '';
    my $own_home = (getpwuid($<))[7];
    my $is_own_home = same_path($home, $own_home);
    open(my $ps, '-|', '/bin/ps', '-axww', '-o', 'pid=', '-o', 'uid=', '-o', 'comm=') or die "ps: $!\n";
    my @found;
    while (my $line = <$ps>) {
        chomp $line;
        next unless $line =~ /^\s*(\d+)\s+(\d+)\s(.*)$/;
        my ($pid, $uid, $path) = ($1, $2, $3);
        next if $pid == $$;
        if ($path eq $abs || $path eq $phys) { push @found, "$pid $path"; next }
        next unless $path =~ m{(?:^|/)Contents/MacOS/Tankard\z|(?:^|/)TankardApp\z};
        next if $uid != $< && $uid != 0;
        if (!$is_own_home) {
            my $env = env_of($pid);
            # HOME runs to the next " KEY=" or the end, so a path with
            # spaces is not cut short and wrongly dropped.
            if (defined $env && $env =~ /(?:^| )HOME=(.*?)(?= [A-Za-z_][A-Za-z0-9_]*=|\z)/s) {
                next unless same_path($1, $home);
            }
        }
        push @found, "$pid $path";
    }
    close $ps or do {
        print STDERR "launch-check-helper.pl: ps failed\n";
        exit 1;
    };
    print "$_\n" for @found;
}

# The process's command line and environment (`ps -E`), or undef when it
# can't be read.
sub env_of {
    my ($pid) = @_;
    open(my $ps, '-|', '/bin/ps', '-E', '-ww', '-p', $pid, '-o', 'command=') or return undef;
    local $/;
    my $text = <$ps>;
    close $ps;
    return defined $text && $text =~ / HOME=/ ? $text : undef;
}

sub mkcache {
    my ($dir) = @_;
    my $fail = sub { print STDERR "$_[0]\n"; return 1 };
    (my $parent = $dir) =~ s{/[^/]+/?\z}{};
    $parent = '/' if $parent eq '';
    my $tmp;
    for (1 .. 20) {
        my $try = sprintf('%s/.tankard-launch-check.%d.%06d', $parent, $$, int(rand(1_000_000)));
        if (mkdir($try, 0700)) { $tmp = $try; last }
        return $fail->("could not make a folder in $parent: $!") unless $!{EEXIST};
    }
    return $fail->("could not make a folder in $parent") unless defined $tmp;
    my $dh;
    unless (sysopen($dh, $tmp, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)) {
        my $e = "$!";
        rmdir $tmp;
        return $fail->("could not open the folder made in $parent: $e");
    }
    my @st = stat($dh);
    unless (@st && -d _ && $st[4] == $<) {
        rmdir $tmp;
        return $fail->("the folder made in $parent is not this user's folder");
    }
    my $id = "$st[0]:$st[1]";
    # renameatx_np(AT_FDCWD, tmp, AT_FDCWD, dir, RENAME_EXCL): macOS
    # syscall 488; AT_FDCWD is -2, RENAME_EXCL 4.
    unless (syscall(488, -2, $tmp, -2, $dir, 4) == 0) {
        my $e = $!{EEXIST} ? 'it appeared meanwhile' : "$!";
        rmdir $tmp;
        return $fail->("could not make $dir ($e)");
    }
    my @at = lstat($dir);
    return $fail->("$dir is not the folder just made") unless @at && -d _ && "$at[0]:$at[1]" eq $id;
    # Empty, read through the handle (the folder itself, wherever it is).
    chdir($dh) or return $fail->("could not enter the folder made: $!");
    opendir(my $list, '.') or return $fail->("could not list the folder made: $!");
    my @in = grep { $_ ne '.' && $_ ne '..' } readdir $list;
    closedir $list;
    return $fail->("$dir was written to while it was made") if @in;
    chmod(0777 & ~umask, $dh) or return $fail->("could not set the mode of $dir: $!");
    print "$id\n";
    return 0;
}

sub rc_of {
    my ($st) = @_;
    return WEXITSTATUS($st) if WIFEXITED($st);
    return 128 + WTERMSIG($st) if WIFSIGNALED($st);
    return 255;
}

sub supervise {
    my ($result, $stopfile, $seconds, $log, $dashes, @command) = @_;
    die "launch-check-helper.pl supervise: bad arguments\n" unless defined $dashes && $dashes eq '--' && @command;
    my $parent = getppid();
    my $asked = 0;
    $SIG{TERM} = $SIG{HUP} = sub { $asked = 1 };
    open(my $out, '>', $result) or die "launch-check-helper.pl: $result: $!\n";
    $out->autoflush(1);
    my $aborted = sub { $asked || -e $stopfile || getppid() != $parent };
    return 3 if $aborted->();

    my $pid = fork();
    die "launch-check-helper.pl: fork: $!\n" unless defined $pid;
    if ($pid == 0) {
        $SIG{TERM} = $SIG{HUP} = 'DEFAULT';
        open(STDIN, '<', '/dev/null');
        open(STDOUT, '>', $log) or _exit(127);
        open(STDERR, '>&', \*STDOUT) or _exit(127);
        exec(@command) or _exit(127);
    }
    print $out "pid $pid\n";

    # The child's status once reaped; undef while its pid is still ours.
    my $status;
    my $gone = sub {
        return 1 if defined $status;
        if (waitpid($pid, WNOHANG) == $pid) { $status = $?; return 1 }
        return 0;
    };
    # Sends signal $_[0] to the child, unless it has been reaped. Returns
    # whether it was sent.
    my $signal = sub { return 0 if $gone->(); kill $_[0], $pid; return 1 };
    my $abort = sub {
        my @also = @_;
        for my $other (@also) { kill 'KILL', $other; waitpid($other, 0) }
        $signal->('KILL');
        unless (defined $status) { waitpid($pid, 0); $status = $? }
        print $out "aborted\n";
        return 3;
    };
    # Polls for up to $_[0] seconds; true once the child is reaped.
    my $wait_gone = sub {
        my $until = time + $_[0];
        while (time < $until) {
            return 1 if $gone->();
            return undef if $aborted->();
            sleep 0.1;
        }
        return $gone->();
    };

    my $up = $wait_gone->($seconds);
    return $abort->() if !defined $up;
    if ($up) {
        print $out 'exited ' . rc_of($status) . "\n";
        return 0;
    }

    # The Quit: a Quit Apple event to this pid only (not reaped, so it is
    # still this child, even if it has just exited).
    my $how = 'quit';
    unless ($gone->()) {
        my $js = "ObjC.import('AppKit'); var a = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($pid); if (a) a.terminate; ''";
        my $osa = fork();
        die "launch-check-helper.pl: fork: $!\n" unless defined $osa;
        if ($osa == 0) {
            $SIG{TERM} = $SIG{HUP} = 'DEFAULT';
            open(STDIN, '<', '/dev/null');
            open(STDOUT, '>', '/dev/null');
            open(STDERR, '>', '/dev/null');
            alarm 10;
            exec 'osascript', '-l', 'JavaScript', '-e', $js or _exit(127);
        }
        my $until = time + 12;
        my $done = 0;
        while (time < $until) {
            if (waitpid($osa, WNOHANG) == $osa) { $done = 1; last }
            return $abort->($osa) if $aborted->();
            sleep 0.1;
        }
        unless ($done) {
            # Not reaped, so this is still the osascript started above.
            kill 'KILL', $osa;
            waitpid($osa, 0);
            print STDERR "launch-check: the Quit's osascript did not finish within 10s; it was stopped\n";
        }
    }
    my $stopped = $wait_gone->(5);
    return $abort->() if !defined $stopped;
    if (!$stopped && $signal->('TERM')) {
        $how = 'TERM';
        print STDERR "launch-check: pid $pid was still up 5s after the Quit; sent it SIGTERM\n";
        $stopped = $wait_gone->(5);
        return $abort->() if !defined $stopped;
        if (!$stopped && $signal->('KILL')) {
            $how = 'KILL';
            print STDERR "launch-check: pid $pid was still up 5s after SIGTERM; sent it SIGKILL\n";
        }
    }
    # Nothing more is sent to it: now it may be reaped.
    unless (defined $status) { waitpid($pid, 0); $status = $? }
    print $out "stopped $how " . rc_of($status) . "\n";
    return 0;
}
