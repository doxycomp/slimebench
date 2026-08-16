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
    browser => [ 1024, 1024, 262144,  0 ],
);

sub usage {
    my $fh = shift // \*STDOUT;
    print {$fh} <<"USAGE";
usage: slimebench.pl [options]   (slimebench @{[SPEC_VERSION]})
  --preset NAME        tiny|small|medium|large|browser
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
    my $target = $cfg{update} eq 'deferred' ? $dep : $grid;
    my ($sdist, $step, $deposit) = @cfg{qw(sensor_dist step deposit)};
    my ($ss, $rs) = @cfg{qw(sensor_steps rot_steps)};

    for my $i (0 .. $N - 1) {
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
        $target->[$idx] += $deposit;

        $adir[$i] = $d;
        $ax[$i]   = $x;
        $ay[$i]   = $y;
    }
}

sub agent_pass_strict {
    my $target = $cfg{update} eq 'deferred' ? $dep : $grid;
    my ($sdist, $step, $deposit) = @cfg{qw(sensor_dist step deposit)};
    my ($ss, $rs) = @cfg{qw(sensor_steps rot_steps)};

    for my $i (0 .. $N - 1) {
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
        $target->[$idx] = f32($target->[$idx] + $deposit);

        $adir[$i] = $d;
        $ax[$i]   = $x;
        $ay[$i]   = $y;
    }
}

sub diffuse_pass {
    my $decay = $cfg{decay};
    for my $y (0 .. $H - 1) {
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
    ($grid, $scratch) = ($scratch, $grid);
}

sub diffuse_pass_strict {
    my $decay = $cfg{decay};
    for my $y (0 .. $H - 1) {
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
    ($grid, $scratch) = ($scratch, $grid);
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
    my $t2 = now_ns();

    $ns_agents  += $t1 - $t0;
    $ns_diffuse += $t2 - $t1;
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

tick() for 1 .. $cfg{warmup};
($ns_agents, $ns_diffuse) = (0, 0);

my @tick_ms;
my $t_start = now_ns();
for my $t (1 .. $cfg{ticks}) {
    my $a = now_ns();
    tick();
    push @tick_ms, (now_ns() - $a) / 1e6;
    if ($cfg{hash_every} && $t % $cfg{hash_every} == 0) {
        printf STDERR "tick %d grid=0x%08X agents=0x%08X\n", $t, hash_grid(), hash_agents();
    }
}
my $ms_total = (now_ns() - $t_start) / 1e6;

if (defined $dump_grid) {
    open my $fh, '>:raw', $dump_grid or die "cannot write $dump_grid: $!";
    print {$fh} pack "f<$CELLS", @$grid;
    close $fh;
}

my $variant = $strict ? 'strict-f32' : 'plain';

if ($want_json) {
    my $n      = scalar @tick_ms;
    my @sorted = sort { $a <=> $b } @tick_ms;
    my $median = $n ? $sorted[ int($n / 2) ] : 0;
    my $p99    = $n ? $sorted[ $n - 1 < int($n * 0.99) ? $n - 1 : int($n * 0.99) ] : 0;
    my $mean   = 0; $mean += $_ for @tick_ms; $mean = $n ? $mean / $n : 0;
    my $cells  = $W * $H;

    printf '{"schema":1,"impl":"perl","backend":"%s","class":"S","preset":"%s",'
         . '"variant":"%s","width":%d,"height":%d,"agents":%d,"ticks":%d,"seed":%d,'
         . '"update":"%s","threads":%d,'
         . '"grid_hash":"0x%08X","agent_hash":"0x%08X","dirtable_hash":"0x%08X",'
         . '"ms_total":%.4f,"ms_agents":%.4f,"ms_diffuse":%.4f,'
         . '"ms_per_tick_mean":%.6f,"ms_per_tick_median":%.6f,"ms_per_tick_p99":%.6f,'
         . '"maups":%.4f,"mcups":%.4f}' . "\n",
        ($strict ? 'strict-f32' : 'headless'), $cfg{preset}, $variant,
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
