#!/usr/bin/env perl
# slimebench -- Perl implementation of SPEC-1.
#
# Conformance tier B by default, tier A with --strict-f32.
#
# Perl has 64-bit IVs, so the 32-bit PRNG arithmetic needs explicit masking
# after every operation -- Perl will happily give you a 64-bit result where C
# would have wrapped.

use strict;
use warnings;
use IO::Handle;
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);

use FindBin;
use lib "$FindBin::Bin/lib";
use Slimebench::DirTable;

use constant {
    SPEC_VERSION => 'SPEC-1',
    MASK32       => 0xFFFFFFFF,
    FNV_OFFSET   => 0x811C9DC5,
    FNV_PRIME    => 0x01000193,
};

my $NDIR = $Slimebench::DirTable::NDIR;
my @COS  = @Slimebench::DirTable::COS;
my @SIN  = @Slimebench::DirTable::SIN;

# ---- CLI (SPEC-1 section 10) --------------------------------------------

my %PRESETS = (
    tiny    => [ 512,  512,  65536,   1000 ],
    small   => [ 1024, 1024, 262144,  1000 ],
    medium  => [ 2048, 2048, 1048576, 1000 ],
    large   => [ 4096, 4096, 4194304, 500 ],
    huge    => [ 8192, 8192, 16777216, 100 ],
    browser => [ 1024, 1024, 262144,  0 ],
);

sub usage {
    my $fh = shift // \*STDOUT;
    print {$fh} <<"USAGE";
usage: slimebench.pl [options]   (slimebench @{[SPEC_VERSION]})
  --preset NAME        tiny|small|medium|large|huge|browser
  --width N --height N powers of two
  --agents N  --ticks N  --warmup N  --seed N
  --update MODE        serial|deferred
  --threads N
  --sensor-dist F  --sensor-steps N  --rot-steps N
  --step F  --deposit F  --decay F
  --headless  --render
  --json  --hash-every N  --dump-grid PATH  --display-max F
  --strict-f32         round every intermediate to f32 (conformance tier A)
  -h, --help
USAGE
}

my %cfg = (
    width => 1024, height => 1024, agents => 262144, ticks => 1000,
    warmup => 0, seed => 12345, threads => 1, update => 'serial',
    sensor_dist => 9.0, step => 1.0, deposit => 10.0, decay => 0.94,
    sensor_steps => 144, rot_steps => 144, hash_every => 0, preset => 'custom',
);
my ($want_json, $dump_grid, $strict, $display_max) = (0, undef, 0, 100.0);

sub need {
    my ($i, $flag) = @_;
    die_usage("$flag requires a value") if $$i + 1 > $#ARGV;
    return $ARGV[ ++$$i ];
}

sub die_usage {
    my $msg = shift;
    print STDERR "error: $msg\n";
    usage(\*STDERR);
    exit 2;
}

for (my $i = 0; $i <= $#ARGV; $i++) {
    my $a = $ARGV[$i];
    if    ($a eq '-h' || $a eq '--help') { usage(); exit 0 }
    elsif ($a eq '--preset') {
        my $n = need(\$i, $a);
        die_usage("unknown preset '$n'") unless exists $PRESETS{$n};
        @cfg{qw(width height agents ticks)} = @{ $PRESETS{$n} };
        $cfg{preset} = $n;
    }
    elsif ($a eq '--width')        { $cfg{width}  = 0 + need(\$i, $a); $cfg{preset} = 'custom' }
    elsif ($a eq '--height')       { $cfg{height} = 0 + need(\$i, $a); $cfg{preset} = 'custom' }
    elsif ($a eq '--agents')       { $cfg{agents} = 0 + need(\$i, $a); $cfg{preset} = 'custom' }
    elsif ($a eq '--ticks')        { $cfg{ticks}  = 0 + need(\$i, $a) }
    elsif ($a eq '--warmup')       { $cfg{warmup} = 0 + need(\$i, $a) }
    elsif ($a eq '--seed')         { $cfg{seed}   = 0 + need(\$i, $a) }
    elsif ($a eq '--threads')      { $cfg{threads} = 0 + need(\$i, $a) }
    elsif ($a eq '--hash-every')   { $cfg{hash_every} = 0 + need(\$i, $a) }
    elsif ($a eq '--sensor-steps') { $cfg{sensor_steps} = 0 + need(\$i, $a) }
    elsif ($a eq '--rot-steps')    { $cfg{rot_steps} = 0 + need(\$i, $a) }
    elsif ($a eq '--sensor-dist')  { $cfg{sensor_dist} = 0 + need(\$i, $a) }
    elsif ($a eq '--step')         { $cfg{step} = 0 + need(\$i, $a) }
    elsif ($a eq '--deposit')      { $cfg{deposit} = 0 + need(\$i, $a) }
    elsif ($a eq '--decay')        { $cfg{decay} = 0 + need(\$i, $a) }
    elsif ($a eq '--display-max')  { $display_max = 0 + need(\$i, $a) }
    elsif ($a eq '--dump-grid')    { $dump_grid = need(\$i, $a) }
    elsif ($a eq '--update') {
        my $m = need(\$i, $a);
        die_usage('--update must be serial|deferred') unless $m =~ /^(serial|deferred)$/;
        $cfg{update} = $m;
    }
    elsif ($a eq '--headless')   { }
    elsif ($a eq '--render')     { }
    elsif ($a eq '--json')       { $want_json = 1 }
    elsif ($a eq '--strict-f32') { $strict = 1 }
    # SPEC-1 section 10: never silently ignore an unknown flag.
    else { die_usage("unknown argument '$a'") }
}

for my $k (qw(width height)) {
    my $v = $cfg{$k};
    die_usage("$k must be a power of two") if $v <= 0 || ($v & ($v - 1));
}

# SPEC-1: parameters are f32. A Perl numeric literal is a double, and 0.94 as a
# double is not 0.94f -- the same trap that bit the TypeScript port.
sub f32 { return unpack 'f<', pack 'f<', $_[0] }
$cfg{$_} = f32($cfg{$_}) for qw(sensor_dist step deposit decay);

# ---- PRNG (SPEC-1 section 3.1) ------------------------------------------

sub splitmix32 {
    my $s = ($_[0] + 0x9E3779B9) & MASK32;
    my $z = $s;
    $z = (($z ^ ($z >> 16)) * 0x21F0AAAD) & MASK32;
    $z = (($z ^ ($z >> 15)) * 0x735A2D97) & MASK32;
    return ($s, $z ^ ($z >> 15));
}

# ---- state ---------------------------------------------------------------

my ($W, $H, $N) = @cfg{qw(width height agents)};
my $CELLS  = $W * $H;
my $LOG2W  = 0; $LOG2W++ while (1 << $LOG2W) < $W;
my $XMASK  = $W - 1;
my $YMASK  = $H - 1;
my $FW     = $W + 0.0;
my $FH     = $H + 0.0;

# Array refs rather than named arrays so the diffusion pass can swap buffers
# in O(1). Perl indexes through a ref at essentially the same cost, and copying
# a million-element array every tick would have dwarfed the simulation.
#
# Packed strings with vec()/substr would be far more memory-efficient (4 bytes
# vs ~24 per element) but are roughly 3x slower per access, so the array of NVs
# is the right trade here; the packed form appears only in I/O and checksums.
my $grid    = [ (0.0) x $CELLS ];
my $scratch = [ (0.0) x $CELLS ];
my $dep     = $cfg{update} eq 'deferred' ? [ (0.0) x $CELLS ] : undef;

my (@ax, @ay, @adir, @arng);

{
    my $sm = $cfg{seed} ^ 0x5BF03635;
    for my $i (0 .. $CELLS - 1) {
        (my $u);
        ($sm, $u) = splitmix32($sm);
        $grid->[$i] = f32((($u >> 8) / 16777216.0) * 100.0);
    }

    for my $i (0 .. $N - 1) {
        my $sma = ($cfg{seed} + 0x9E3779B9 * ($i + 1)) & MASK32;
        my @s;
        for my $k (0 .. 3) { (my $u); ($sma, $u) = splitmix32($sma); push @s, $u }
        $s[0] = 1 if (($s[0] | $s[1] | $s[2] | $s[3]) == 0);

        my $r1 = xoshiro(\@s);
        my $r2 = xoshiro(\@s);
        my $r3 = xoshiro(\@s);
        $ax[$i]   = f32((($r1 >> 8) / 16777216.0) * $FW);
        $ay[$i]   = f32((($r2 >> 8) / 16777216.0) * $FH);
        $adir[$i] = $r3 % $NDIR;
        $arng[$i] = \@s;
    }
}

sub xoshiro {
    my $s = shift;
    my ($s0, $s1, $s2, $s3) = @$s;
    my $t0     = ($s0 + $s3) & MASK32;
    my $result = (((($t0 << 7) | ($t0 >> 25)) & MASK32) + $s0) & MASK32;
    my $t      = ($s1 << 9) & MASK32;
    $s2 ^= $s0;
    $s3 ^= $s1;
    $s1 ^= $s2;
    $s0 ^= $s3;
    $s2 ^= $t;
    $s3 = (($s3 << 11) | ($s3 >> 21)) & MASK32;
    @$s = ($s0, $s1, $s2, $s3);
    return $result;
}

# ---- simulation ----------------------------------------------------------

my ($ns_agents, $ns_diffuse) = (0, 0);

sub now_ns { return int(clock_gettime(CLOCK_MONOTONIC) * 1e9) }

sub agent_pass {
    my ($lo, $hi, $aidx) = @_;
    ($lo, $hi) = (0, $N) unless defined $hi;
    my $target = $cfg{update} eq 'deferred' ? $dep : $grid;
    my ($sdist, $step, $deposit) = @cfg{qw(sensor_dist step deposit)};
    my ($ss, $rs) = @cfg{qw(sensor_steps rot_steps)};

    for my $i ($lo .. $hi - 1) {
        my $d = $adir[$i];
        my $x = $ax[$i];
        my $y = $ay[$i];

        my $dl = ($d - $ss + $NDIR) % $NDIR;
        my $dr = ($d + $ss) % $NDIR;

        my ($sx, $sy, $fl, $fc, $fr);

        $sx = $x + $COS[$dl] * $sdist; $sx += $FW if $sx < 0; $sx -= $FW if $sx >= $FW;
        $sy = $y + $SIN[$dl] * $sdist; $sy += $FH if $sy < 0; $sy -= $FH if $sy >= $FH;
        $fl = $grid->[ ((int($sy) & $YMASK) << $LOG2W) | (int($sx) & $XMASK) ];

        $sx = $x + $COS[$d] * $sdist;  $sx += $FW if $sx < 0; $sx -= $FW if $sx >= $FW;
        $sy = $y + $SIN[$d] * $sdist;  $sy += $FH if $sy < 0; $sy -= $FH if $sy >= $FH;
        $fc = $grid->[ ((int($sy) & $YMASK) << $LOG2W) | (int($sx) & $XMASK) ];

        $sx = $x + $COS[$dr] * $sdist; $sx += $FW if $sx < 0; $sx -= $FW if $sx >= $FW;
        $sy = $y + $SIN[$dr] * $sdist; $sy += $FH if $sy < 0; $sy -= $FH if $sy >= $FH;
        $fr = $grid->[ ((int($sy) & $YMASK) << $LOG2W) | (int($sx) & $XMASK) ];

        if ($fc >= $fl && $fc >= $fr) {
            # straight on
        }
        elsif ($fc < $fl && $fc < $fr) {
            $d = (xoshiro($arng[$i]) & 1)
               ? ($d + $rs) % $NDIR
               : ($d - $rs + $NDIR) % $NDIR;
        }
        elsif ($fl > $fr) { $d = ($d - $rs + $NDIR) % $NDIR }
        else              { $d = ($d + $rs) % $NDIR }

        $x += $COS[$d] * $step; $x += $FW if $x < 0; $x -= $FW if $x >= $FW;
        $y += $SIN[$d] * $step; $y += $FH if $y < 0; $y -= $FH if $y >= $FH;

        my $idx = ((int($y) & $YMASK) << $LOG2W) | (int($x) & $XMASK);
        # Class P records the target cell instead of depositing; the pool
        # applies every agent's deposit afterwards, in ascending agent index.
        if ($aidx) { $aidx->[$i] = $idx } else { $target->[$idx] += $deposit }

        $adir[$i] = $d;
        $ax[$i]   = $x;
        $ay[$i]   = $y;
    }
}

sub agent_pass_strict {
    my ($lo, $hi, $aidx) = @_;
    ($lo, $hi) = (0, $N) unless defined $hi;
    my $target = $cfg{update} eq 'deferred' ? $dep : $grid;
    my ($sdist, $step, $deposit) = @cfg{qw(sensor_dist step deposit)};
    my ($ss, $rs) = @cfg{qw(sensor_steps rot_steps)};

    for my $i ($lo .. $hi - 1) {
        my $d = $adir[$i];
        my $x = $ax[$i];
        my $y = $ay[$i];

        my $dl = ($d - $ss + $NDIR) % $NDIR;
        my $dr = ($d + $ss) % $NDIR;

        my ($sx, $sy, $fl, $fc, $fr);

        $sx = f32($x + f32($COS[$dl] * $sdist));
        $sx = f32($sx + $FW) if $sx < 0; $sx = f32($sx - $FW) if $sx >= $FW;
        $sy = f32($y + f32($SIN[$dl] * $sdist));
        $sy = f32($sy + $FH) if $sy < 0; $sy = f32($sy - $FH) if $sy >= $FH;
        $fl = $grid->[ ((int($sy) & $YMASK) << $LOG2W) | (int($sx) & $XMASK) ];

        $sx = f32($x + f32($COS[$d] * $sdist));
        $sx = f32($sx + $FW) if $sx < 0; $sx = f32($sx - $FW) if $sx >= $FW;
        $sy = f32($y + f32($SIN[$d] * $sdist));
        $sy = f32($sy + $FH) if $sy < 0; $sy = f32($sy - $FH) if $sy >= $FH;
        $fc = $grid->[ ((int($sy) & $YMASK) << $LOG2W) | (int($sx) & $XMASK) ];

        $sx = f32($x + f32($COS[$dr] * $sdist));
        $sx = f32($sx + $FW) if $sx < 0; $sx = f32($sx - $FW) if $sx >= $FW;
        $sy = f32($y + f32($SIN[$dr] * $sdist));
        $sy = f32($sy + $FH) if $sy < 0; $sy = f32($sy - $FH) if $sy >= $FH;
        $fr = $grid->[ ((int($sy) & $YMASK) << $LOG2W) | (int($sx) & $XMASK) ];

        if ($fc >= $fl && $fc >= $fr) {
            # straight on
        }
        elsif ($fc < $fl && $fc < $fr) {
            $d = (xoshiro($arng[$i]) & 1)
               ? ($d + $rs) % $NDIR
               : ($d - $rs + $NDIR) % $NDIR;
        }
        elsif ($fl > $fr) { $d = ($d - $rs + $NDIR) % $NDIR }
        else              { $d = ($d + $rs) % $NDIR }

        $x = f32($x + f32($COS[$d] * $step));
        $x = f32($x + $FW) if $x < 0; $x = f32($x - $FW) if $x >= $FW;
        $y = f32($y + f32($SIN[$d] * $step));
        $y = f32($y + $FH) if $y < 0; $y = f32($y - $FH) if $y >= $FH;

        my $idx = ((int($y) & $YMASK) << $LOG2W) | (int($x) & $XMASK);
        if ($aidx) { $aidx->[$i] = $idx }
        else       { $target->[$idx] = f32($target->[$idx] + $deposit) }

        $adir[$i] = $d;
        $ax[$i]   = $x;
        $ay[$i]   = $y;
    }
}

sub diffuse_pass {
    my ($y0, $y1) = @_;
    ($y0, $y1) = (0, $H) unless defined $y1;
    my $decay = $cfg{decay};
    for my $y ($y0 .. $y1 - 1) {
        my $rowm = ((($y - 1) & $YMASK) << $LOG2W);
        my $row0 = ($y << $LOG2W);
        my $rowp = ((($y + 1) & $YMASK) << $LOG2W);
        for my $x (0 .. $W - 1) {
            my $xm = ($x - 1) & $XMASK;
            my $xp = ($x + 1) & $XMASK;
            my $acc = $grid->[ $rowm | $xm ];
            $acc += $grid->[ $rowm | $x ];
            $acc += $grid->[ $rowm | $xp ];
            $acc += $grid->[ $row0 | $xm ];
            $acc += 4.0 * $grid->[ $row0 | $x ];
            $acc += $grid->[ $row0 | $xp ];
            $acc += $grid->[ $rowp | $xm ];
            $acc += $grid->[ $rowp | $x ];
            $acc += $grid->[ $rowp | $xp ];
            $scratch->[ $row0 | $x ] = ($acc / 12.0) * $decay;
        }
    }
}

sub diffuse_pass_strict {
    my ($y0, $y1) = @_;
    ($y0, $y1) = (0, $H) unless defined $y1;
    my $decay = $cfg{decay};
    for my $y ($y0 .. $y1 - 1) {
        my $rowm = ((($y - 1) & $YMASK) << $LOG2W);
        my $row0 = ($y << $LOG2W);
        my $rowp = ((($y + 1) & $YMASK) << $LOG2W);
        for my $x (0 .. $W - 1) {
            my $xm = ($x - 1) & $XMASK;
            my $xp = ($x + 1) & $XMASK;
            my $acc = $grid->[ $rowm | $xm ];
            $acc = f32($acc + $grid->[ $rowm | $x ]);
            $acc = f32($acc + $grid->[ $rowm | $xp ]);
            $acc = f32($acc + $grid->[ $row0 | $xm ]);
            $acc = f32($acc + f32(4.0 * $grid->[ $row0 | $x ]));
            $acc = f32($acc + $grid->[ $row0 | $xp ]);
            $acc = f32($acc + $grid->[ $rowp | $xm ]);
            $acc = f32($acc + $grid->[ $rowp | $x ]);
            $acc = f32($acc + $grid->[ $rowp | $xp ]);
            $scratch->[ $row0 | $x ] = f32(f32($acc / 12.0) * $decay);
        }
    }
}

sub tick {
    my $t0 = now_ns();
    $strict ? agent_pass_strict() : agent_pass();
    my $t1 = now_ns();

    if ($cfg{update} eq 'deferred') {
        if ($strict) {
            for my $i (0 .. $CELLS - 1) { $grid->[$i] = f32($grid->[$i] + $dep->[$i]); $dep->[$i] = 0.0 }
        } else {
            for my $i (0 .. $CELLS - 1) { $grid->[$i] += $dep->[$i]; $dep->[$i] = 0.0 }
        }
    }

    $strict ? diffuse_pass_strict() : diffuse_pass();
    ($grid, $scratch) = ($scratch, $grid);
    my $t2 = now_ns();

    $ns_agents  += $t1 - $t0;
    $ns_diffuse += $t2 - $t1;
}


# ---- class P: fork + pipe (SPEC-1 section 5.6) ---------------------------
#
# Perl has ithreads, and they are the wrong tool here. Measured on this
# machine, a `threads::shared` array costs 7.6x a plain one for the random
# read-modify-write the deposit pass does, and 17x for a sequential one --
# while pack/unpack of the same 262144 floats costs 12 ms, about what one
# plain random pass costs. The diffusion stencil reads nine cells per output
# cell, so a shared grid can never win: it would have to make up 7.6x before
# the first thread helps.
#
# So the workers are forked processes with private grids, and the only thing
# that crosses between them is packed binary. Two round trips per tick:
#
#   1. every worker steps its own slice of the agents against its own grid
#      (read-only during the pass in `deferred` mode, so the copies agree),
#      and sends back the target cell of each of its agents;
#   2. the parent concatenates those slices -- which, because the ranges are
#      contiguous and ascending, *is* the full array in agent order -- and
#      broadcasts it. Everyone applies the whole deposit list.
#
# Then the same shape for the diffusion pass over row blocks.
#
# That replicated reduction is stronger than either strategy in SPEC-1 5.6:
# every worker applies every deposit in ascending agent index, which is
# exactly the serial chain, so the result is bit-identical for any worker
# count without needing the binned sort. It costs the deposit and merge passes
# being done N times instead of once -- which is the trade Perl's memory model
# forces, and the reason the speedup ceiling here is the agent pass alone.

sub _blob_send {
    my ($fh, $blob) = @_;
    print {$fh} pack('N', length $blob), $blob or die "write: $!";
    $fh->flush;
}

sub _blob_recv {
    my ($fh) = @_;
    my $hdr = '';
    while (length($hdr) < 4) {
        my $n = read($fh, my $chunk, 4 - length $hdr);
        die "eof reading header" unless $n;
        $hdr .= $chunk;
    }
    my $len = unpack('N', $hdr);
    my $buf = '';
    while (length($buf) < $len) {
        my $n = read($fh, my $chunk, $len - length $buf);
        die "eof reading body" unless $n;
        $buf .= $chunk;
    }
    return $buf;
}

# Contiguous split of [0, n) into `parts`; part `i` is [lo, hi). Same rule as
# the C reference, so the concatenation lands in agent order.
sub _split {
    my ($n, $parts, $i) = @_;
    my $base = int($n / $parts);
    my $rem  = $n % $parts;
    my $lo = $i * $base + ($i < $rem ? $i : $rem);
    return ($lo, $lo + $base + ($i < $rem ? 1 : 0));
}

sub _apply_deposits {
    my ($blob) = @_;
    my @all = unpack('L<*', $blob);
    my $deposit = $cfg{deposit};
    if ($strict) {
        $dep->[$_] = f32($dep->[$_] + $deposit) for @all;
    } else {
        $dep->[$_] += $deposit for @all;
    }
    if ($strict) {
        for my $i (0 .. $CELLS - 1) { $grid->[$i] = f32($grid->[$i] + $dep->[$i]); $dep->[$i] = 0.0 }
    } else {
        for my $i (0 .. $CELLS - 1) { $grid->[$i] += $dep->[$i]; $dep->[$i] = 0.0 }
    }
}

# Returns the per-tick wall times. Runs in the parent as rank 0.
sub run_parallel {
    my ($nproc, $warmup, $ticks) = @_;
    if ($cfg{update} ne 'deferred') {
        print STDERR "error: --threads > 1 requires --update deferred.\n";
        print STDERR "       SPEC-1 'serial' makes an agent's deposit visible to the\n";
        print STDERR "       next agent in the same tick, which is a sequential\n";
        print STDERR "       dependency; see SPEC-1 section 5.5.\n";
        exit 2;
    }

    my (@to_child, @from_child, @pids);
    for my $r (1 .. $nproc - 1) {
        pipe(my $c_rd, my $p_wr) or die "pipe: $!";
        pipe(my $p_rd, my $c_wr) or die "pipe: $!";
        $p_wr->autoflush(1); $c_wr->autoflush(1);
        my $pid = fork();
        die "fork: $!" unless defined $pid;
        if ($pid == 0) {
            close $p_wr; close $p_rd;
            _worker_loop($r, $nproc, $c_rd, $c_wr, $warmup + $ticks);
            exit 0;
        }
        close $c_rd; close $c_wr;
        push @to_child, $p_wr;
        push @from_child, $p_rd;
        push @pids, $pid;
    }

    my ($lo, $hi) = _split($N, $nproc, 0);
    my ($ylo, $yhi) = _split($H, $nproc, 0);
    my @aidx;
    my @tick_ms;

    for my $t (1 .. $warmup + $ticks) {
        my $t0 = now_ns();

        # -- agents ---------------------------------------------------------
        $strict ? agent_pass_strict($lo, $hi, \@aidx) : agent_pass($lo, $hi, \@aidx);
        my $blob = pack('L<*', @aidx[$lo .. $hi - 1]);
        $blob .= _blob_recv($_) for @from_child;
        _blob_send($_, $blob) for @to_child;
        _apply_deposits($blob);

        # -- diffusion ------------------------------------------------------
        $strict ? diffuse_pass_strict($ylo, $yhi) : diffuse_pass($ylo, $yhi);
        # 'd<' and not 'f<': in tier B a Perl scalar holds a double, and shipping
        # the grid as f32 would silently round the whole thing once per tick.
        # It costs twice the bytes and it is the difference between matching
        # the single-process run and not.
        my $gblob = pack('d<*', @{$scratch}[($ylo << $LOG2W) .. ($yhi << $LOG2W) - 1]);
        $gblob .= _blob_recv($_) for @from_child;
        _blob_send($_, $gblob) for @to_child;
        @$grid = unpack('d<*', $gblob);

        push @tick_ms, (now_ns() - $t0) / 1e6 if $t > $warmup;
    }

    # The parent only ever stepped its own agents; collect the rest for the
    # agent checksum.
    for my $k (0 .. $#from_child) {
        my $b = _blob_recv($from_child[$k]);
        my ($rlo, $rhi) = _split($N, $nproc, $k + 1);
        my $cnt = $rhi - $rlo;
        my @xs   = unpack('d<*', substr($b, 0, 8 * $cnt));
        my @ys   = unpack('d<*', substr($b, 8 * $cnt, 8 * $cnt));
        my @ds   = unpack('L<*', substr($b, 16 * $cnt));
        @ax[$rlo .. $rhi - 1]   = @xs;
        @ay[$rlo .. $rhi - 1]   = @ys;
        @adir[$rlo .. $rhi - 1] = @ds;
    }
    waitpid($_, 0) for @pids;
    return @tick_ms;
}

sub _worker_loop {
    my ($rank, $nproc, $rd, $wr, $total) = @_;
    my ($lo, $hi) = _split($N, $nproc, $rank);
    my ($ylo, $yhi) = _split($H, $nproc, $rank);
    my @aidx;

    for (1 .. $total) {
        $strict ? agent_pass_strict($lo, $hi, \@aidx) : agent_pass($lo, $hi, \@aidx);
        _blob_send($wr, pack('L<*', @aidx[$lo .. $hi - 1]));
        _apply_deposits(_blob_recv($rd));

        $strict ? diffuse_pass_strict($ylo, $yhi) : diffuse_pass($ylo, $yhi);
        _blob_send($wr, pack('d<*', @{$scratch}[($ylo << $LOG2W) .. ($yhi << $LOG2W) - 1]));
        @$grid = unpack('d<*', _blob_recv($rd));
    }

    # Final agent state for the parent's checksum. Doubles, because that is
    # what a Perl scalar holds; packing them as f32 here would round values
    # that the non-strict mode deliberately keeps in double.
    my $cnt = $hi - $lo;
    _blob_send($wr, pack('d<*', @ax[$lo .. $hi - 1])
                  . pack('d<*', @ay[$lo .. $hi - 1])
                  . pack('L<*', @adir[$lo .. $hi - 1]));
}

# ---- checksums (SPEC-1 section 6) ---------------------------------------

sub hash_grid {
    my $h = FNV_OFFSET;
    # Round-trip through packed f32 so the hash sees the same bit patterns the
    # compiled implementations do, whatever precision the NVs carry.
    for my $w (unpack 'L<*', pack "f<$CELLS", @$grid) {
        $h = (($h ^ $w) * FNV_PRIME) & MASK32;
    }
    return $h;
}

sub hash_agents {
    my $h  = FNV_OFFSET;
    my @bx = unpack "L<$N", pack "f<$N", @ax;
    my @by = unpack "L<$N", pack "f<$N", @ay;
    for my $i (0 .. $N - 1) {
        $h = (($h ^ $bx[$i]) * FNV_PRIME) & MASK32;
        $h = (($h ^ $by[$i]) * FNV_PRIME) & MASK32;
        $h = (($h ^ $adir[$i]) * FNV_PRIME) & MASK32;
    }
    return $h;
}

sub dirtable_hash {
    my $h = FNV_OFFSET;
    for my $w (@Slimebench::DirTable::COS_BITS, @Slimebench::DirTable::SIN_BITS) {
        $h = (($h ^ $w) * FNV_PRIME) & MASK32;
    }
    return $h;
}

# ---- main ----------------------------------------------------------------

my @tick_ms;
my $ms_total;

if ($cfg{threads} > 1) {
    # Class P. Processes, not ithreads -- see the comment above run_parallel.
    my $t_start = now_ns();
    @tick_ms = run_parallel($cfg{threads}, $cfg{warmup}, $cfg{ticks});
    $ms_total = (now_ns() - $t_start) / 1e6;
    # The phases interleave across processes, so an agent/diffuse split would
    # be meaningless. Class P reports wall time.
    ($ns_agents, $ns_diffuse) = (int($ms_total * 1e6), 0);
} else {
    tick() for 1 .. $cfg{warmup};
    ($ns_agents, $ns_diffuse) = (0, 0);

    my $t_start = now_ns();
    for my $t (1 .. $cfg{ticks}) {
        my $a = now_ns();
        tick();
        push @tick_ms, (now_ns() - $a) / 1e6;
        if ($cfg{hash_every} && $t % $cfg{hash_every} == 0) {
            printf STDERR "tick %d grid=0x%08X agents=0x%08X\n", $t, hash_grid(), hash_agents();
        }
    }
    $ms_total = (now_ns() - $t_start) / 1e6;
}

if (defined $dump_grid) {
    open my $fh, '>:raw', $dump_grid or die "cannot write $dump_grid: $!";
    print {$fh} pack "f<$CELLS", @$grid;
    close $fh;
}

my $variant = $strict ? 'strict-f32' : 'plain';
$variant .= '+fork' if $cfg{threads} > 1;
my $class = $cfg{threads} > 1 ? 'P' : 'S';

if ($want_json) {
    my $n      = scalar @tick_ms;
    my @sorted = sort { $a <=> $b } @tick_ms;
    my $median = $n ? $sorted[ int($n / 2) ] : 0;
    my $p99    = $n ? $sorted[ $n - 1 < int($n * 0.99) ? $n - 1 : int($n * 0.99) ] : 0;
    my $mean   = 0; $mean += $_ for @tick_ms; $mean = $n ? $mean / $n : 0;
    my $cells  = $W * $H;

    printf '{"schema":1,"impl":"perl","backend":"%s","class":"%s","preset":"%s",'
         . '"variant":"%s","width":%d,"height":%d,"agents":%d,"ticks":%d,"seed":%d,'
         . '"update":"%s","threads":%d,'
         . '"grid_hash":"0x%08X","agent_hash":"0x%08X","dirtable_hash":"0x%08X",'
         . '"ms_total":%.4f,"ms_agents":%.4f,"ms_diffuse":%.4f,'
         . '"ms_per_tick_mean":%.6f,"ms_per_tick_median":%.6f,"ms_per_tick_p99":%.6f,'
         . '"maups":%.4f,"mcups":%.4f}' . "\n",
        ($cfg{threads} > 1 ? 'fork' : $strict ? 'strict-f32' : 'headless'),
        $class, $cfg{preset}, $variant,
        $W, $H, $N, $n, $cfg{seed}, $cfg{update}, $cfg{threads},
        hash_grid(), hash_agents(), dirtable_hash(),
        $ms_total, $ns_agents / 1e6, $ns_diffuse / 1e6,
        $mean, $median, $p99,
        $ms_total > 0 ? $N * $n / $ms_total / 1000 : 0,
        $ms_total > 0 ? $cells * $n / $ms_total / 1000 : 0;
} else {
    printf "%s %dx%d agents=%d ticks=%d update=%s variant=%s\n",
        $cfg{preset}, $W, $H, $N, $cfg{ticks}, $cfg{update}, $variant;
    printf "  grid_hash  0x%08X\n", hash_grid();
    printf "  agent_hash 0x%08X\n", hash_agents();
    printf "  total      %.2f ms  (%.4f ms/tick)\n",
        $ms_total, $cfg{ticks} ? $ms_total / $cfg{ticks} : 0;
    printf "  agents     %.2f ms\n", $ns_agents / 1e6;
    printf "  diffuse    %.2f ms\n", $ns_diffuse / 1e6;
}
