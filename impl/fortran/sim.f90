! slimebench -- Fortran implementation of SPEC-1 (conformance tier A).
!
! Why Fortran is here
! -------------------
! Every other statically typed port in this project had to be argued into
! exactness. C needs -ffp-contract=off, Go needs a redundant float32()
! conversion around each product, Java needed JEP 306 to happen, OCaml has to
! call a runtime function per operation because it has no f32 type at all.
! Fortran has had a native single-precision real since 1957 and an arithmetic
! model that says what it does, so the port is a transcription.
!
! One flag is still required, and it is the same one C needs:
! -ffp-contract=off. The Fortran standard permits a processor to evaluate an
! expression in any mathematically equivalent way, and gfortran reads that as
! permission to fuse a multiply and an add. Without the flag the stencil's
! `acc + 4.0*g` becomes one FMA with one rounding, the grid hash moves, and
! the port is tier B while looking like tier A. build.sh passes it; this
! comment exists so nobody removes it.
!
! Integers
! --------
! Fortran has no unsigned type, and signed overflow is not something to rely on
! -- gfortran optimises on the assumption that it does not happen. So the PRNG
! runs in integer(int64) with an explicit mask after every step, the same
! approach the OCaml port takes for the same reason. The masked values are
! always non-negative, which is what makes ISHFT's right shift a logical one.

module sim
  use iso_fortran_env, only: real32, real64, int32, int64
  use dirtable, only: NDIR, COS_BITS, SIN_BITS
  implicit none

  integer(int64), parameter :: MASK32 = int(z'FFFFFFFF', int64)
  integer(int64), parameter :: FNV_OFFSET = int(z'811C9DC5', int64)
  integer(int64), parameter :: FNV_PRIME = int(z'01000193', int64)

  type :: config_t
    integer :: width = 1024, height = 1024
    integer :: agents = 262144
    integer :: ticks = 1000, warmup = 0
    integer :: seed = 12345
    integer :: threads = 1
    character(len=16) :: update = 'serial'
    real(real32) :: sensor_dist = 9.0_real32
    real(real32) :: step = 1.0_real32
    real(real32) :: deposit = 10.0_real32
    real(real32) :: decay = 0.94_real32
    integer :: sensor_steps = 144, rot_steps = 144
    integer :: hash_every = 0
    character(len=16) :: preset = 'custom'
  end type config_t

  type :: sim_t
    type(config_t) :: cfg
    integer :: log2w, xmask, ymask
    ! ALLOCATABLE, not POINTER: an allocatable array cannot alias another, and
    ! that is the assumption the whole language is built on. Swapping the two
    ! buffers therefore has to move data or move the allocation, which is why
    ! swap_buffers uses MOVE_ALLOC rather than exchanging two references.
    real(real32), allocatable :: grid(:), scratch(:), dep(:)
    real(real32), allocatable :: ax(:), ay(:)
    integer, allocatable :: adir(:), arng(:)
    real(real32) :: cos_t(0:NDIR-1), sin_t(0:NDIR-1)
    integer(int64) :: ns_agents = 0, ns_diffuse = 0
    logical :: deferred = .false.
  end type sim_t

contains

  ! ---- PRNG (SPEC-1 section 3.1) -----------------------------------------

  subroutine splitmix32(state, draw)
    integer(int64), intent(inout) :: state
    integer(int64), intent(out) :: draw
    integer(int64) :: z
    state = iand(state + int(z'9E3779B9', int64), MASK32)
    z = state
    z = iand(ieor(z, ishft(z, -16)) * int(z'21F0AAAD', int64), MASK32)
    z = iand(ieor(z, ishft(z, -15)) * int(z'735A2D97', int64), MASK32)
    draw = iand(ieor(z, ishft(z, -15)), MASK32)
  end subroutine splitmix32

  pure function rotl32(x, k) result(r)
    integer(int64), intent(in) :: x
    integer, intent(in) :: k
    integer(int64) :: r
    r = iand(ior(ishft(x, k), ishft(x, k - 32)), MASK32)
  end function rotl32

  ! Advances the four words at arng(o:o+3) and returns one draw.
  function xoshiro128pp(arng, o) result(res)
    integer, intent(inout) :: arng(0:)
    integer, intent(in) :: o
    integer(int64) :: res, s0, s1, s2, s3, t
    s0 = iand(int(arng(o), int64), MASK32)
    s1 = iand(int(arng(o+1), int64), MASK32)
    s2 = iand(int(arng(o+2), int64), MASK32)
    s3 = iand(int(arng(o+3), int64), MASK32)
    res = iand(rotl32(iand(s0 + s3, MASK32), 7) + s0, MASK32)
    t = iand(ishft(s1, 9), MASK32)
    s2 = ieor(s2, s0)
    s3 = ieor(s3, s1)
    s1 = ieor(s1, s2)
    s0 = ieor(s0, s3)
    s2 = ieor(s2, t)
    s3 = rotl32(s3, 11)
    arng(o)   = int(s0, int32)
    arng(o+1) = int(s1, int32)
    arng(o+2) = int(s2, int32)
    arng(o+3) = int(s3, int32)
  end function xoshiro128pp

  ! Exact: the shifted value is below 2^24 and 16777216 is a power of two.
  pure function rnd01(u) result(r)
    integer(int64), intent(in) :: u
    real(real64) :: r
    r = real(ishft(u, -8), real64) / 16777216.0_real64
  end function rnd01

  ! SPEC-1 section 2.2 -- not a modulo, one conditional shift.
  pure function wrapf(v, m) result(r)
    real(real32), intent(in) :: v, m
    real(real32) :: r
    r = v
    if (r < 0.0_real32) r = r + m
    if (r >= m) r = r - m
  end function wrapf

  ! ---- construction (SPEC-1 section 3.3) ---------------------------------

  subroutine sim_create(s, cfg, ok, why)
    type(sim_t), intent(out) :: s
    type(config_t), intent(in) :: cfg
    logical, intent(out) :: ok
    character(len=*), intent(out) :: why
    integer :: i, k, o, cells
    integer(int64) :: sm, sa, draw
    real(real64) :: fw, fh

    ok = .false.
    why = ''
    if (cfg%width <= 0 .or. iand(cfg%width, cfg%width - 1) /= 0) then
      why = 'width must be a power of two'; return
    end if
    if (cfg%height <= 0 .or. iand(cfg%height, cfg%height - 1) /= 0) then
      why = 'height must be a power of two'; return
    end if

    s%cfg = cfg
    s%deferred = (cfg%update == 'deferred')
    s%log2w = 0
    do while (ishft(1, s%log2w) < cfg%width)
      s%log2w = s%log2w + 1
    end do
    s%xmask = cfg%width - 1
    s%ymask = cfg%height - 1

    cells = cfg%width * cfg%height
    allocate(s%grid(0:cells-1), s%scratch(0:cells-1))
    s%grid = 0.0_real32
    s%scratch = 0.0_real32
    if (s%deferred) then
      allocate(s%dep(0:cells-1))
      s%dep = 0.0_real32
    else
      allocate(s%dep(0:0))
    end if
    allocate(s%ax(0:cfg%agents-1), s%ay(0:cfg%agents-1))
    allocate(s%adir(0:cfg%agents-1), s%arng(0:cfg%agents*4-1))

    do i = 0, NDIR - 1
      s%cos_t(i) = transfer(COS_BITS(i+1), 1.0_real32)
      s%sin_t(i) = transfer(SIN_BITS(i+1), 1.0_real32)
    end do

    ! The product is computed in double and rounded once on the store, which
    ! is what C does: rnd01 is exact and 100 needs 7 bits, so the exact product
    ! fits in a double and the single rounding is the only one.
    sm = ieor(int(cfg%seed, int64), int(z'5BF03635', int64))
    do i = 0, cells - 1
      call splitmix32(sm, draw)
      s%grid(i) = real(rnd01(draw) * 100.0_real64, real32)
    end do

    fw = real(cfg%width, real64)
    fh = real(cfg%height, real64)
    do i = 0, cfg%agents - 1
      sa = iand(int(cfg%seed, int64) + int(z'9E3779B9', int64) * int(i + 1, int64), MASK32)
      o = i * 4
      do k = 0, 3
        call splitmix32(sa, draw)
        s%arng(o + k) = int(draw, int32)
      end do
      if (ior(ior(s%arng(o), s%arng(o+1)), ior(s%arng(o+2), s%arng(o+3))) == 0) &
        s%arng(o) = 1
      s%ax(i) = real(rnd01(xoshiro128pp(s%arng, o)) * fw, real32)
      s%ay(i) = real(rnd01(xoshiro128pp(s%arng, o)) * fh, real32)
      s%adir(i) = int(mod(xoshiro128pp(s%arng, o), int(NDIR, int64)), int32)
    end do
    ok = .true.
  end subroutine sim_create

  ! ---- the passes ---------------------------------------------------------

  subroutine agent_pass(s)
    type(sim_t), intent(inout) :: s
    integer :: i, d, dl, dr, idx, ss, rs, nd, xmask, ymask, log2w
    real(real32) :: x, y, sx, sy, fl, fc, fr, fw, fh, sdist, stp, dep

    ss = s%cfg%sensor_steps; rs = s%cfg%rot_steps; nd = NDIR
    xmask = s%xmask; ymask = s%ymask; log2w = s%log2w
    fw = real(s%cfg%width, real32); fh = real(s%cfg%height, real32)
    sdist = s%cfg%sensor_dist; stp = s%cfg%step; dep = s%cfg%deposit

    ! Class P, and the whole of it.
    !
    ! Without -fopenmp these lines are comments and this is the serial port;
    ! with it, one directive. Everything an agent writes except the deposit is
    ! indexed by the agent -- ax(i), ay(i), adir(i), arng(i*4..i*4+3) -- so
    ! there is nothing to coordinate there. The grid is read-only in deferred
    ! mode. Only dep(idx) collides, and only the deposit needs the atomic.
    !
    ! `serial` mode is excluded by the caller: it lets an agent see its
    ! predecessors' deposits within the same tick, which is not
    ! deterministically parallelisable even in principle (SPEC-1 5.5).
    !$omp parallel do default(shared) &
    !$omp   private(i, d, dl, dr, idx, x, y, sx, sy, fl, fc, fr) &
    !$omp   schedule(static)
    do i = 0, s%cfg%agents - 1
      d = s%adir(i)
      x = s%ax(i)
      y = s%ay(i)
      dl = mod(d - ss + nd, nd)
      dr = mod(d + ss, nd)

      ! Each sensor read is written out: the order of the two wraps is
      ! normative and a helper would hide it.
      sx = wrapf(x + s%cos_t(dl) * sdist, fw)
      sy = wrapf(y + s%sin_t(dl) * sdist, fh)
      fl = s%grid(ior(ishft(iand(int(sy), ymask), log2w), iand(int(sx), xmask)))

      sx = wrapf(x + s%cos_t(d) * sdist, fw)
      sy = wrapf(y + s%sin_t(d) * sdist, fh)
      fc = s%grid(ior(ishft(iand(int(sy), ymask), log2w), iand(int(sx), xmask)))

      sx = wrapf(x + s%cos_t(dr) * sdist, fw)
      sy = wrapf(y + s%sin_t(dr) * sdist, fh)
      fr = s%grid(ior(ishft(iand(int(sy), ymask), log2w), iand(int(sx), xmask)))

      if (fc >= fl .and. fc >= fr) then
        continue
      else if (fc < fl .and. fc < fr) then
        ! Only the dead-end case draws from the stream (SPEC-1 5.3).
        if (iand(xoshiro128pp(s%arng, i * 4), 1_int64) /= 0) then
          d = mod(d + rs, nd)
        else
          d = mod(d - rs + nd, nd)
        end if
      else if (fl > fr) then
        d = mod(d - rs + nd, nd)
      else
        d = mod(d + rs, nd)
      end if

      x = wrapf(x + s%cos_t(d) * stp, fw)
      y = wrapf(y + s%sin_t(d) * stp, fh)
      idx = ior(ishft(iand(int(y), ymask), log2w), iand(int(x), xmask))
      if (s%deferred) then
        ! Bit-exact under any interleaving, and not by luck. SPEC-1's deposit
        ! is a constant, so a cell's value depends on how many agents landed
        ! there and not on which ones or in what order: ((g+d)+d)+d is the
        ! same however the adds are scheduled. That is what lets this be one
        ! atomic where the other ten class P ports need a counting sort.
        !$omp atomic
        s%dep(idx) = s%dep(idx) + dep
      else
        s%grid(idx) = s%grid(idx) + dep
      end if
      s%adir(i) = d
      s%ax(i) = x
      s%ay(i) = y
    end do
    !$omp end parallel do
  end subroutine agent_pass

  subroutine merge_dep(s)
    type(sim_t), intent(inout) :: s
    integer :: i
    if (.not. s%deferred) return
    ! One cell per iteration, no sharing.
    !$omp parallel do default(shared) private(i) schedule(static)
    do i = 0, size(s%grid) - 1
      s%grid(i) = s%grid(i) + s%dep(i)
      s%dep(i) = 0.0_real32
    end do
    !$omp end parallel do
  end subroutine merge_dep

  ! SPEC-1 section 5.4. The summation order is normative -- do not reorder,
  ! and do not let the compiler fuse: see -ffp-contract=off in build.sh.
  subroutine diffuse_pass(s)
    type(sim_t), intent(inout) :: s
    integer :: x, y, w, h, rowm, row0, rowp, xm, xp, log2w, xmask, ymask
    real(real32) :: acc, decay

    w = s%cfg%width; h = s%cfg%height
    log2w = s%log2w; xmask = s%xmask; ymask = s%ymask
    decay = s%cfg%decay

    ! Output cells are independent, so this one is bit-identical whatever the
    ! schedule -- the same argument SPEC-1 8.1 makes for the vector kernels.
    !$omp parallel do default(shared) &
    !$omp   private(x, y, rowm, row0, rowp, xm, xp, acc) &
    !$omp   schedule(static)
    do y = 0, h - 1
      rowm = ishft(iand(y - 1, ymask), log2w)
      row0 = ishft(y, log2w)
      rowp = ishft(iand(y + 1, ymask), log2w)
      do x = 0, w - 1
        xm = iand(x - 1, xmask)
        xp = iand(x + 1, xmask)
        acc = s%grid(ior(rowm, xm))
        acc = acc + s%grid(ior(rowm, x))
        acc = acc + s%grid(ior(rowm, xp))
        acc = acc + s%grid(ior(row0, xm))
        acc = acc + 4.0_real32 * s%grid(ior(row0, x))
        acc = acc + s%grid(ior(row0, xp))
        acc = acc + s%grid(ior(rowp, xm))
        acc = acc + s%grid(ior(rowp, x))
        acc = acc + s%grid(ior(rowp, xp))
        s%scratch(ior(row0, x)) = acc / 12.0_real32 * decay
      end do
    end do
    !$omp end parallel do
  end subroutine diffuse_pass

  ! MOVE_ALLOC transfers the allocation itself, so this is two pointer moves
  ! and no copy -- the Fortran spelling of swapping two buffers.
  subroutine swap_buffers(s)
    type(sim_t), intent(inout) :: s
    real(real32), allocatable :: tmp(:)
    call move_alloc(s%grid, tmp)
    call move_alloc(s%scratch, s%grid)
    call move_alloc(tmp, s%scratch)
  end subroutine swap_buffers

  subroutine sim_tick(s)
    type(sim_t), intent(inout) :: s
    integer(int64) :: t0, t1, t2, rate
    call system_clock(t0, rate)
    call agent_pass(s)
    call system_clock(t1)
    call merge_dep(s)
    call diffuse_pass(s)
    call swap_buffers(s)
    call system_clock(t2)
    s%ns_agents = s%ns_agents + (t1 - t0) * 1000000000_int64 / rate
    s%ns_diffuse = s%ns_diffuse + (t2 - t1) * 1000000000_int64 / rate
  end subroutine sim_tick

  ! ---- checksums (SPEC-1 section 6) --------------------------------------

  pure function bits_u32(v) result(b)
    real(real32), intent(in) :: v
    integer(int64) :: b
    b = iand(int(transfer(v, 1_int32), int64), MASK32)
  end function bits_u32

  function hash_grid(s) result(h)
    type(sim_t), intent(in) :: s
    integer(int64) :: h
    integer :: i
    h = FNV_OFFSET
    do i = 0, size(s%grid) - 1
      h = iand(ieor(h, bits_u32(s%grid(i))) * FNV_PRIME, MASK32)
    end do
  end function hash_grid

  function hash_agents(s) result(h)
    type(sim_t), intent(in) :: s
    integer(int64) :: h
    integer :: i
    h = FNV_OFFSET
    do i = 0, s%cfg%agents - 1
      h = iand(ieor(h, bits_u32(s%ax(i))) * FNV_PRIME, MASK32)
      h = iand(ieor(h, bits_u32(s%ay(i))) * FNV_PRIME, MASK32)
      h = iand(ieor(h, int(s%adir(i), int64)) * FNV_PRIME, MASK32)
    end do
  end function hash_agents

  function dirtable_hash() result(h)
    integer(int64) :: h
    integer :: i
    h = FNV_OFFSET
    do i = 1, NDIR
      h = iand(ieor(h, iand(int(COS_BITS(i), int64), MASK32)) * FNV_PRIME, MASK32)
    end do
    do i = 1, NDIR
      h = iand(ieor(h, iand(int(SIN_BITS(i), int64), MASK32)) * FNV_PRIME, MASK32)
    end do
  end function dirtable_hash

end module sim
