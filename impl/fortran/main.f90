! slimebench -- Fortran headless benchmark (class S).
program slimebench
  use iso_fortran_env, only: real32, real64, int32, int64, error_unit
  use sim
!$ use omp_lib, only: omp_set_num_threads, omp_get_max_threads
  implicit none

  type(config_t) :: cfg
  type(sim_t) :: s
  logical :: want_json, ok
  character(len=256) :: arg, val, dump_path, why
  character(len=16) :: variant
  integer :: i, n, t, ios
  integer(int64) :: t0, t1, rate
  real(real64) :: ms_total
  real(real64), allocatable :: tick_ms(:)

  want_json = .false.
  dump_path = ''
  i = 1
  n = command_argument_count()
  do while (i <= n)
    call get_command_argument(i, arg)
    select case (trim(arg))
    case ('-h', '--help')
      call usage(0)
    case ('--json')
      want_json = .true.
    case ('--headless', '--no-simd')
      continue
    case ('--simd')
      call fail('this target has no vectorised kernel')
    case default
      ! Everything else takes exactly one value.
      if (i + 1 > n) call fail(trim(arg)//' requires a value')
      i = i + 1
      call get_command_argument(i, val)
      select case (trim(arg))
      case ('--preset')
        call apply_preset(cfg, trim(val))
      case ('--width');  cfg%width = int_arg(val);  cfg%preset = 'custom'
      case ('--height'); cfg%height = int_arg(val); cfg%preset = 'custom'
      case ('--agents'); cfg%agents = int_arg(val); cfg%preset = 'custom'
      case ('--ticks');  cfg%ticks = int_arg(val)
      case ('--warmup'); cfg%warmup = int_arg(val)
      case ('--seed');   cfg%seed = int_arg(val)
      case ('--threads')
        cfg%threads = int_arg(val)
      case ('--hash-every');   cfg%hash_every = int_arg(val)
      case ('--sensor-steps'); cfg%sensor_steps = int_arg(val)
      case ('--rot-steps');    cfg%rot_steps = int_arg(val)
      case ('--sensor-dist');  cfg%sensor_dist = real_arg(val)
      case ('--step');         cfg%step = real_arg(val)
      case ('--deposit');      cfg%deposit = real_arg(val)
      case ('--decay');        cfg%decay = real_arg(val)
      case ('--dump-grid');    dump_path = val
      ! Accepted for CLI compatibility, unused by a headless target.
      case ('--display-max', '--deposit-reduce')
        continue
      case ('--update')
        if (trim(val) /= 'serial' .and. trim(val) /= 'deferred') &
          call fail('--update must be serial|deferred')
        cfg%update = trim(val)
      case default
        ! SPEC-1 section 10: never silently ignore an unknown flag.
        call fail("unknown argument '"//trim(arg)//"'")
      end select
    end select
    i = i + 1
  end do

  ! Class P is deferred only: `serial` lets an agent see its predecessors'
  ! deposits within the same tick and is not deterministically parallelisable
  ! even in principle (SPEC-1 5.5).
  if (cfg%threads > 1 .and. cfg%update /= 'deferred') &
    call fail('--threads > 1 requires --update deferred (SPEC-1 5.5)')
  ! Unconditionally, including for one thread. Guarded with `threads > 1`
  ! this left the OpenMP default in place -- every core on the machine -- so
  ! `--threads 1` ran the parallel region 32-wide while reporting
  ! "threads": 1. Nothing failed and the hash still matched, because the
  ! deposit is an atomic add of a constant and the result does not depend on
  ! the thread count. Only the baseline of the whole sweep was wrong.
!$ call omp_set_num_threads(cfg%threads)

  call sim_create(s, cfg, ok, why)
  if (.not. ok) call fail(trim(why))

  do t = 1, cfg%warmup
    call sim_tick(s)
  end do
  s%ns_agents = 0
  s%ns_diffuse = 0

  allocate(tick_ms(max(cfg%ticks, 1)))
  tick_ms = 0.0_real64
  call system_clock(t0, rate)
  do t = 1, cfg%ticks
    block
      integer(int64) :: a, b
      call system_clock(a)
      call sim_tick(s)
      call system_clock(b)
      tick_ms(t) = real(b - a, real64) * 1000.0_real64 / real(rate, real64)
    end block
    if (cfg%hash_every /= 0 .and. mod(t, max(cfg%hash_every, 1)) == 0) then
      write(error_unit, '(A,I0,A,Z8.8,A,Z8.8)') 'tick ', t, &
        ' grid=0x', hash_grid(s), ' agents=0x', hash_agents(s)
    end if
  end do
  call system_clock(t1)
  ms_total = real(t1 - t0, real64) * 1000.0_real64 / real(rate, real64)

  if (len_trim(dump_path) > 0) call dump_grid(s, trim(dump_path))

  ! Named for what the binary actually is: without -fopenmp the directives are
  ! comments and this is the serial port, so the two builds must not share a
  ! row. The !$ sentinel is only compiled when OpenMP is on.
  variant = 'scalar'
!$ variant = 'openmp'

  if (want_json) then
    call print_json(s, ms_total, tick_ms(1:cfg%ticks))
  else
    call print_human(s, ms_total)
  end if

contains

  subroutine usage(code)
    integer, intent(in) :: code
    write(*, '(A)') 'usage: slimebench [options]   (slimebench SPEC-1)'
    write(*, '(A)') '  --preset NAME        tiny|small|medium|large|huge|browser'
    write(*, '(A)') '  --width N --height N powers of two'
    write(*, '(A)') '  --agents N  --ticks N  --warmup N  --seed N'
    write(*, '(A)') '  --update MODE        serial|deferred'
    write(*, '(A)') '  --sensor-dist F  --sensor-steps N  --rot-steps N'
    write(*, '(A)') '  --step F  --deposit F  --decay F'
    write(*, '(A)') '  --headless  --json  --hash-every N  --dump-grid PATH'
    write(*, '(A)') '  -h, --help'
    stop
    if (code /= 0) continue
  end subroutine usage

  subroutine fail(msg)
    character(len=*), intent(in) :: msg
    write(error_unit, '(A)') 'error: '//msg
    stop 2
  end subroutine fail

  function int_arg(v) result(r)
    character(len=*), intent(in) :: v
    integer :: r, e
    read(v, *, iostat=e) r
    if (e /= 0) call fail("'"//trim(v)//"' is not an integer")
  end function int_arg

  function real_arg(v) result(r)
    character(len=*), intent(in) :: v
    real(real32) :: r
    integer :: e
    read(v, *, iostat=e) r
    if (e /= 0) call fail("'"//trim(v)//"' is not a number")
  end function real_arg

  subroutine apply_preset(c, name)
    type(config_t), intent(inout) :: c
    character(len=*), intent(in) :: name
    select case (name)
    case ('tiny');    c%width=512;  c%height=512;  c%agents=65536;    c%ticks=1000
    case ('small');   c%width=1024; c%height=1024; c%agents=262144;   c%ticks=1000
    case ('medium');  c%width=2048; c%height=2048; c%agents=1048576;  c%ticks=1000
    case ('large');   c%width=4096; c%height=4096; c%agents=4194304;  c%ticks=500
    case ('huge');    c%width=8192; c%height=8192; c%agents=16777216; c%ticks=100
    case ('browser'); c%width=1024; c%height=1024; c%agents=262144;   c%ticks=0
    case default;     call fail("unknown preset '"//name//"'")
    end select
    c%preset = name
  end subroutine apply_preset

  ! Raw little-endian f32, one word per cell -- the same bytes every other port
  ! writes, so the tolerant conformance gate has one reader for all of them.
  subroutine dump_grid(sm, path)
    type(sim_t), intent(in) :: sm
    character(len=*), intent(in) :: path
    integer :: u, k
    open(newunit=u, file=path, access='stream', form='unformatted', &
         status='replace', iostat=ios)
    if (ios /= 0) call fail('cannot open '//path)
    do k = 0, size(sm%grid) - 1
      write(u) sm%grid(k)
    end do
    close(u)
  end subroutine dump_grid

  subroutine print_human(sm, total)
    type(sim_t), intent(in) :: sm
    real(real64), intent(in) :: total
    write(*, '(A,1X,I0,A,I0,A,I0,A,I0,A,A)') trim(sm%cfg%preset), &
      sm%cfg%width, 'x', sm%cfg%height, ' agents=', sm%cfg%agents, &
      ' ticks=', sm%cfg%ticks, ' update=', trim(sm%cfg%update)
    write(*, '(A,Z8.8)') '  grid_hash  0x', hash_grid(sm)
    write(*, '(A,Z8.8)') '  agent_hash 0x', hash_agents(sm)
    write(*, '(A)') '  total      '//trim(jnum(total, 2))//' ms  ('// &
      trim(jnum(total / real(max(sm%cfg%ticks, 1), real64), 4))//' ms/tick)'
    write(*, '(A)') '  agents     '// &
      trim(jnum(real(sm%ns_agents, real64) / 1e6_real64, 2))//' ms'
    write(*, '(A)') '  diffuse    '// &
      trim(jnum(real(sm%ns_diffuse, real64) / 1e6_real64, 2))//' ms'
  end subroutine print_human

  ! gfortran's F0.d format drops the leading zero: 0.089236 comes out as
  ! ".089236", which is not valid JSON -- the grammar requires a digit before
  ! the point. Every number below goes through here instead.
  function jnum(x, nd) result(str)
    real(real64), intent(in) :: x
    integer, intent(in) :: nd
    character(len=40) :: buf, str
    write(buf, '(F0.'//char(48 + nd)//')') x
    buf = adjustl(buf)
    if (buf(1:1) == '.') then
      str = '0'//trim(buf)
    else if (buf(1:2) == '-.') then
      str = '-0'//trim(buf(2:))
    else
      str = trim(buf)
    end if
  end function jnum

  subroutine print_json(sm, total, tms)
    type(sim_t), intent(in) :: sm
    real(real64), intent(in) :: total
    real(real64), intent(in) :: tms(:)
    real(real64) :: srt(size(tms)), median, p99, mean, cells, maups, mcups
    integer :: k, j, m
    real(real64) :: tmp
    k = size(tms)
    median = 0.0_real64; p99 = 0.0_real64; mean = 0.0_real64
    if (k > 0) then
      srt = tms
      ! Insertion sort: k is the tick count, this runs once, and pulling in a
      ! sort library for it would be the only dependency in the port.
      do j = 2, k
        tmp = srt(j)
        m = j - 1
        do while (m >= 1)
          if (srt(m) <= tmp) exit
          srt(m + 1) = srt(m)
          m = m - 1
        end do
        srt(m + 1) = tmp
      end do
      median = srt(k / 2 + 1)
      p99 = srt(min(k, int(real(k, real64) * 0.99_real64) + 1))
      mean = sum(tms) / real(k, real64)
    end if
    cells = real(sm%cfg%width, real64) * real(sm%cfg%height, real64)
    maups = 0.0_real64; mcups = 0.0_real64
    if (total > 0.0_real64) then
      maups = real(sm%cfg%agents, real64) * real(k, real64) / total / 1000.0_real64
      mcups = cells * real(k, real64) / total / 1000.0_real64
    end if

    write(*, '(A)', advance='no') '{"schema":1,"impl":"fortran","backend":"headless"'
    write(*, '(A)', advance='no') ',"class":"'//merge('P', 'S', sm%cfg%threads > 1)//'"'
    write(*, '(A)', advance='no') ',"preset":"'//trim(sm%cfg%preset)// &
      '","variant":"'//trim(variant)//'"'
    write(*, '(A,I0,A,I0,A,I0,A,I0,A,I0)', advance='no') &
      ',"width":', sm%cfg%width, ',"height":', sm%cfg%height, &
      ',"agents":', sm%cfg%agents, ',"ticks":', k, ',"seed":', sm%cfg%seed
    write(*, '(A)', advance='no') ',"update":"'//trim(sm%cfg%update)//'"'
    write(*, '(A,I0)', advance='no') ',"threads":', sm%cfg%threads
    write(*, '(A,Z8.8,A,Z8.8,A,Z8.8,A)', advance='no') &
      ',"grid_hash":"0x', hash_grid(sm), '","agent_hash":"0x', hash_agents(sm), &
      '","dirtable_hash":"0x', dirtable_hash(), '"'
    write(*, '(A)', advance='no') &
      ',"ms_total":'//trim(jnum(total, 4))// &
      ',"ms_agents":'//trim(jnum(real(sm%ns_agents, real64) / 1e6_real64, 4))// &
      ',"ms_diffuse":'//trim(jnum(real(sm%ns_diffuse, real64) / 1e6_real64, 4))
    write(*, '(A)', advance='no') &
      ',"ms_per_tick_mean":'//trim(jnum(mean, 6))// &
      ',"ms_per_tick_median":'//trim(jnum(median, 6))// &
      ',"ms_per_tick_p99":'//trim(jnum(p99, 6))
    write(*, '(A)') ',"maups":'//trim(jnum(maups, 4))// &
      ',"mcups":'//trim(jnum(mcups, 4))//'}'
  end subroutine print_json

end program slimebench
