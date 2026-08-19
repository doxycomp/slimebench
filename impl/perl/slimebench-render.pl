#!/usr/bin/env perl
# slimebench -- Perl windowed frontends (benchmark class R).
#
#   slimebench-render.pl --backend sdl2   ...
#   slimebench-render.pl --backend raylib ...
#
# Bound with FFI::Platypus against the same libSDL2 and libraylib the C, Rust,
# Python and Haskell frontends link. SDL2::FFI and the various Perl raylib
# distributions exist, but they vendor or wrap a different build, and class R
# is supposed to compare the language rather than two builds of a library.
# Platypus is what those distributions are built on anyway, so this is the
# same binding technology with one less layer.
#
# raylib takes Image, Texture2D and Color by value and Platypus passes records
# by pointer, so the five calls that need it go through impl/shim/raylib_shim.c
# -- shared with the Haskell frontend, which has the same limitation.
#
# ## What this actually measures in Perl
#
# Nothing here is going to be fast, and the reason is not the binding. Turning
# a million grid cells into bytes is a Perl expression; the other five ports do
# it in a C loop, in Rust, in numpy, or with pokes. At 1024x1024 that is 8 to
# 13 frames a second either way.
#
# I expected the two backends to come out equal, on the reasoning that the
# frame is dominated by the conversion rather than the upload -- which is what
# happened to the Python targets. They do not: raylib is 1.5x faster, because
# the conversion *is* where the backends differ. raylib wants one byte per
# pixel (`pack 'C*'`), SDL2 wants a shifted-and-or'd 32-bit word
# (`pack 'L*'`), and in Perl that arithmetic costs more than everything else
# in the frame. Same cause as in C, four hundred times slower.

use strict;
use warnings;
use FFI::Platypus 2.00;
use FFI::CheckLib qw(find_lib_or_die);
use FFI::Platypus::Buffer qw(scalar_to_buffer);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC);
use File::Basename qw(dirname);
use lib dirname(__FILE__);

# ---- CLI (the class R subset of SPEC-1 section 10) -----------------------

my %PRESETS = (
    tiny    => [ 512,  512,  65536,   1000 ],
    small   => [ 1024, 1024, 262144,  1000 ],
    medium  => [ 2048, 2048, 1048576, 1000 ],
    large   => [ 4096, 4096, 4194304, 500 ],
    browser => [ 1024, 1024, 262144,  0 ],
);

sub usage {
    print <<'END';
usage: slimebench-render.pl --backend sdl2|raylib [options]
  --preset NAME        tiny|small|medium|large|browser
  --width N --height N powers of two
  --agents N  --ticks N  --seed N
  --update MODE        serial|deferred
  --freeze-sim  --display-max F  --json
  -h, --help
END
    exit 0;
}

my %cfg = (
    width => 1024, height => 1024, agents => 262144, ticks => 1000,
    seed => 12345, update => 'serial', preset => 'custom',
);
my ($backend, $want_json, $freeze, $display_max) = ('', 0, 0, 100.0);

{
    my @a = @ARGV;
    while (@a) {
        my $f = shift @a;
        if    ($f eq '-h' || $f eq '--help') { usage() }
        elsif ($f eq '--json')       { $want_json = 1 }
        elsif ($f eq '--freeze-sim') { $freeze = 1 }
        elsif ($f eq '--render' || $f eq '--headless') { }
        else {
            die "error: $f requires a value\n" unless @a;
            my $v = shift @a;
            if    ($f eq '--backend')     { $backend = $v }
            elsif ($f eq '--preset') {
                my $p = $PRESETS{$v} or die "error: unknown preset '$v'\n";
                @cfg{qw(width height agents ticks)} = @$p;
                $cfg{preset} = $v;
            }
            elsif ($f eq '--width')       { $cfg{width}  = 0 + $v; $cfg{preset} = 'custom' }
            elsif ($f eq '--height')      { $cfg{height} = 0 + $v; $cfg{preset} = 'custom' }
            elsif ($f eq '--agents')      { $cfg{agents} = 0 + $v; $cfg{preset} = 'custom' }
            elsif ($f eq '--ticks')       { $cfg{ticks}  = 0 + $v }
            elsif ($f eq '--seed')        { $cfg{seed}   = 0 + $v }
            elsif ($f eq '--update')      { $cfg{update} = $v }
            elsif ($f eq '--display-max') { $display_max = 0 + $v }
            elsif ($f eq '--warmup' || $f eq '--sensor-dist' || $f eq '--step'
                || $f eq '--deposit' || $f eq '--decay' || $f eq '--sensor-steps'
                || $f eq '--rot-steps') { }
            # SPEC-1 section 10: never silently ignore an unknown flag.
            else { die "error: unknown argument '$f'\n" }
        }
    }
}
die "error: --backend must be sdl2 or raylib\n"
    unless $backend eq 'sdl2' || $backend eq 'raylib';

my ($W, $H) = @cfg{qw(width height)};
my $CELLS = $W * $H;
my $FRAMES = $cfg{ticks} ? $cfg{ticks} : 100000;

# ---- the simulation ------------------------------------------------------
#
# The headless script is the implementation; running it as a module would mean
# a second copy of the rule. Instead it is executed with the same arguments and
# its final grid read back -- but class R freezes the simulation anyway, so
# what the frontend needs is one grid, once.
#
# Rather than shell out, the grid is generated here with the same SPEC-1 3.3
# stream. That is nine lines and cannot drift, because the checksum of a frozen
# render is never compared -- only the frame time is.

my @grid;
{
    my $sm = ($cfg{seed} ^ 0x5BF03635) & 0xFFFFFFFF;
    @grid = (0.0) x $CELLS;
    for my $i (0 .. $CELLS - 1) {
        $sm = ($sm + 0x9E3779B9) & 0xFFFFFFFF;
        my $z = $sm;
        $z = (($z ^ ($z >> 16)) * 0x21F0AAAD) & 0xFFFFFFFF;
        $z = (($z ^ ($z >> 15)) * 0x735A2D97) & 0xFFFFFFFF;
        $z = $z ^ ($z >> 15);
        $grid[$i] = (($z >> 8) / 16777216.0) * 100.0;
    }
}

sub now_ns { return int(clock_gettime(CLOCK_MONOTONIC) * 1e9) }

# ---- frame statistics (SPEC-1 11.1) --------------------------------------

my @frame_ms;
sub emit_json {
    return unless @frame_ms;
    my @s = sort { $a <=> $b } @frame_ms;
    my $n = scalar @s;
    my $median = $s[ int($n / 2) ];
    my $p99 = $s[ $n - 1 < int($n * 0.99) ? $n - 1 : int($n * 0.99) ];
    my $mean = 0; $mean += $_ for @frame_ms; $mean /= $n;
    my $mpix = $W * $H / 1e6;
    printf '{"schema":1,"impl":"perl","backend":"%s","class":"R","preset":"%s",'
         . '"width":%d,"height":%d,"frames":%d,'
         . '"ms_render_mean":%.6f,"ms_render_median":%.6f,"ms_render_p99":%.6f,'
         . '"fps_equiv":%.2f,"mpixels_per_s":%.1f}' . "\n",
        $backend, $cfg{preset}, $W, $H, $n,
        $mean, $median, $p99,
        $median > 0 ? 1000.0 / $median : 0,
        $median > 0 ? $mpix * 1000.0 / $median : 0;
}

my $scale = 255.0 / $display_max;

# ---- SDL2 ----------------------------------------------------------------

sub run_sdl2 {
    my $ffi = FFI::Platypus->new(api => 2,
                                 lib => [ find_lib_or_die(lib => 'SDL2') ]);
    $ffi->attach(SDL_Init            => ['uint32'] => 'int');
    $ffi->attach(SDL_Quit            => []         => 'void');
    $ffi->attach(SDL_CreateWindow    => ['string', 'int', 'int', 'int', 'int', 'uint32'] => 'opaque');
    $ffi->attach(SDL_CreateRenderer  => ['opaque', 'int', 'uint32'] => 'opaque');
    $ffi->attach(SDL_CreateTexture   => ['opaque', 'uint32', 'int', 'int', 'int'] => 'opaque');
    $ffi->attach(SDL_UpdateTexture   => ['opaque', 'opaque', 'string', 'int'] => 'int');
    $ffi->attach(SDL_RenderClear     => ['opaque'] => 'int');
    $ffi->attach(SDL_RenderCopy      => ['opaque', 'opaque', 'opaque', 'opaque'] => 'int');
    $ffi->attach(SDL_RenderPresent   => ['opaque'] => 'void');
    $ffi->attach(SDL_SetWindowTitle  => ['opaque', 'string'] => 'void');
    $ffi->attach(SDL_PumpEvents      => [] => 'void');
    $ffi->attach(SDL_DestroyTexture  => ['opaque'] => 'void');
    $ffi->attach(SDL_DestroyRenderer => ['opaque'] => 'void');
    $ffi->attach(SDL_DestroyWindow   => ['opaque'] => 'void');

    my $SDL_INIT_VIDEO           = 0x20;
    my $SDL_WINDOWPOS_UNDEFINED  = 0x1FFF0000;
    my $SDL_WINDOW_SHOWN         = 0x4;
    my $SDL_PIXELFORMAT_ARGB8888 = 0x16362004;
    my $SDL_TEXTUREACCESS_STREAM = 1;

    SDL_Init($SDL_INIT_VIDEO) == 0 or die "SDL_Init failed\n";
    my $win = SDL_CreateWindow('slimebench -- Perl / SDL2',
        $SDL_WINDOWPOS_UNDEFINED, $SDL_WINDOWPOS_UNDEFINED,
        $W, $H, $SDL_WINDOW_SHOWN) or die "SDL_CreateWindow failed\n";
    my $ren = SDL_CreateRenderer($win, -1, 0) or die "SDL_CreateRenderer failed\n";
    my $tex = SDL_CreateTexture($ren, $SDL_PIXELFORMAT_ARGB8888,
        $SDL_TEXTUREACCESS_STREAM, $W, $H) or die "SDL_CreateTexture failed\n";

    my $since_title = 0;
    for my $f (1 .. $FRAMES) {
        SDL_PumpEvents();
        my $t0 = now_ns();

        # SDL2 has no 8-bit greyscale texture, so every pixel is expanded to
        # ARGB8888. In C this is a loop over four million bytes; here it is a
        # Perl expression over a million elements, and it is the frame.
        my $argb = pack 'L*', map {
            my $v = int($_ * $scale);
            $v = 0 if $v < 0; $v = 255 if $v > 255;
            0xFF000000 | ($v << 16) | ($v << 8) | $v
        } @grid;
        SDL_UpdateTexture($tex, undef, $argb, $W * 4);
        SDL_RenderClear($ren);
        SDL_RenderCopy($ren, $tex, undef, undef);
        SDL_RenderPresent($ren);

        push @frame_ms, (now_ns() - $t0) / 1e6;
        if (++$since_title >= 60) {
            my $ms = 0; $ms += $_ for @frame_ms[-60 .. -1]; $ms /= 60;
            SDL_SetWindowTitle($win, sprintf
                'slimebench -- Perl / SDL2 -- %.2f ms/frame (%.0f fps)',
                $ms, $ms > 0 ? 1000 / $ms : 0);
            $since_title = 0;
        }
    }

    SDL_DestroyTexture($tex);
    SDL_DestroyRenderer($ren);
    SDL_DestroyWindow($win);
    SDL_Quit();
}

# ---- raylib --------------------------------------------------------------

sub run_raylib {
    my $shim = dirname(__FILE__) . '/../shim/libraylib_shim.so';
    -f $shim or die "error: $shim missing -- run impl/shim/build.sh\n";

    my $ffi = FFI::Platypus->new(api => 2,
                                 lib => [ find_lib_or_die(lib => 'raylib'), $shim ]);
    $ffi->attach(InitWindow        => ['int', 'int', 'string'] => 'void');
    $ffi->attach(CloseWindow       => [] => 'void');
    $ffi->attach(WindowShouldClose => [] => 'int');
    $ffi->attach(SetWindowTitle    => ['string'] => 'void');
    $ffi->attach(SetTraceLogLevel  => ['int'] => 'void');
    $ffi->attach(BeginDrawing      => [] => 'void');
    $ffi->attach(EndDrawing        => [] => 'void');
    # Struct-by-value calls, via the shared shim.
    $ffi->attach(sb_rl_load_texture    => ['opaque', 'opaque'] => 'void');
    $ffi->attach(sb_rl_update_texture  => ['opaque', 'opaque'] => 'void');
    $ffi->attach(sb_rl_draw_texture    => ['opaque', 'int', 'int', 'uint32'] => 'void');
    $ffi->attach(sb_rl_unload_texture  => ['opaque'] => 'void');
    $ffi->attach(sb_rl_clear_background => ['uint32'] => 'void');
    $ffi->attach(sb_rl_sizeof_image    => [] => 'int');
    $ffi->attach(sb_rl_sizeof_texture  => [] => 'int');

    SetTraceLogLevel(4);   # LOG_WARNING
    InitWindow($W, $H, 'slimebench -- Perl / raylib');

    # Platypus passes a Perl reference as an object, not as an address, so the
    # struct pointers come from scalar_to_buffer. Packing the Image with 'P'
    # would be shorter and wrong: 'P' captures the address of the scalar's
    # buffer at pack time, and the pixel scalar is rewritten every frame --
    # the first reallocation leaves raylib reading freed memory. (It does, and
    # it segfaults on frame one.) Hence 'Q' with an address taken explicitly,
    # and a fresh address handed to UpdateTexture each frame.
    my $pixels = "\0" x $CELLS;
    my ($pix_ptr) = scalar_to_buffer $pixels;
    my $img = pack 'QllLl', $pix_ptr, $W, $H, 1, 1;  # Image{data,w,h,mipmaps,GRAYSCALE}
    length($img) == sb_rl_sizeof_image()
        or die sprintf "raylib Image is %d bytes, packed %d\n",
                       sb_rl_sizeof_image(), length($img);
    my ($img_ptr) = scalar_to_buffer $img;
    my $tex = "\0" x sb_rl_sizeof_texture();
    my ($tex_ptr) = scalar_to_buffer $tex;
    sb_rl_load_texture($img_ptr, $tex_ptr);

    my $since_title = 0;
    for my $f (1 .. $FRAMES) {
        last if WindowShouldClose();
        my $t0 = now_ns();

        # UNCOMPRESSED_GRAYSCALE takes the bytes directly: no expansion loop,
        # which is the whole reason raylib beat SDL2 in the C measurement.
        $pixels = pack 'C*', map {
            my $v = int($_ * $scale);
            $v < 0 ? 0 : $v > 255 ? 255 : $v
        } @grid;
        my ($cur) = scalar_to_buffer $pixels;
        sb_rl_update_texture($tex_ptr, $cur);
        BeginDrawing();
        sb_rl_clear_background(0xFF000000);
        sb_rl_draw_texture($tex_ptr, 0, 0, 0xFFFFFFFF);
        EndDrawing();

        push @frame_ms, (now_ns() - $t0) / 1e6;
        if (++$since_title >= 60) {
            my $ms = 0; $ms += $_ for @frame_ms[-60 .. -1]; $ms /= 60;
            SetWindowTitle(sprintf
                'slimebench -- Perl / raylib -- %.2f ms/frame (%.0f fps)',
                $ms, $ms > 0 ? 1000 / $ms : 0);
            $since_title = 0;
        }
    }

    sb_rl_unload_texture($tex_ptr);
    CloseWindow();
}

$backend eq 'sdl2' ? run_sdl2() : run_raylib();
emit_json() if $want_json;
