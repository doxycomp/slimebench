using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;

namespace Slimebench;

/// <summary>
/// The diffusion stencil through .NET's SIMD types (class V).
///
/// <para><b>The question.</b> Class V has been three languages reaching the
/// vector unit through intrinsics tied to one instruction set. .NET offers two
/// answers instead of one, and they are not equivalent:</para>
///
/// <list type="bullet">
/// <item><see cref="Vector{T}"/> — width chosen by the runtime, portable, no
/// instruction set named anywhere in the source.</item>
/// <item><see cref="Vector512{T}"/> — the width named explicitly, guarded by
/// <c>IsHardwareAccelerated</c>.</item>
/// </list>
///
/// <para><b>And the portable one will not use AVX-512.</b> On this machine
/// <c>Vector512.IsHardwareAccelerated</c> and <c>Avx512F.IsSupported</c> are
/// both true, and <c>Vector&lt;float&gt;.Count</c> is 8 — 256 bits.
/// <c>DOTNET_PreferredVectorBitWidth=512</c> does not change it. So the two
/// paths here are the same relationship as impl/c's <c>o3-v3</c> and
/// <c>o3-native</c> profiles: eight lanes against sixteen, from source that
/// differs only in which type it names.</para>
///
/// <para><b>Why it stays conformance tier A.</b> SPEC-1 §8.1: the stencil does
/// no cross-lane work. Nine loads, eight adds, one multiply, one divide, all
/// elementwise, one output cell per lane — each lane performs exactly the
/// scalar computation for its own cell, in the same order. That is the same
/// argument that makes impl/c, impl/cpp and impl/rust tier A here.</para>
///
/// <para><b>On <c>LoadUnsafe</c>.</b> The safe constructor
/// <c>new Vector&lt;float&gt;(array, index)</c> bounds-checks every load, and
/// there are nine per iteration; measured, that alone costs 37 % of the vector
/// loop (8.67 against 5.48 ms of diffusion at 256²). <c>Vector.LoadUnsafe</c> is the API .NET provides for exactly
/// this, needs no <c>unsafe</c> keyword, and is what makes the comparison
/// against C's unchecked kernel a comparison of vector code rather than of
/// bounds checks. The rest of the port keeps its checks; §3 prices those.</para>
///
/// <para>The two wrapping columns stay scalar. They are the only cells whose
/// neighbours are not contiguous.</para>
/// </summary>
internal static class Simd
{
    /// <summary>Lanes of the portable <see cref="Vector{T}"/>.</summary>
    public static int PortableWidth => Vector<float>.Count;

    public static bool PortableAvailable => Vector.IsHardwareAccelerated && PortableWidth > 1;

    public static bool WideAvailable => Vector512.IsHardwareAccelerated;

    /// <summary>Lanes actually used, given the requested mode.</summary>
    public static int Width(bool portable) =>
        (!portable && WideAvailable) ? Vector512<float>.Count : PortableWidth;

    public static bool Available(bool portable) => portable ? PortableAvailable
                                                            : (WideAvailable || PortableAvailable);

    public static string Name(bool portable) =>
        Available(portable) ? $"vector{Width(portable) * 32}" : "scalar";

    /// <summary>
    /// SPEC-1 §5.4 over rows [y0,y1), vectorised. The summation order is
    /// normative and identical to <see cref="Sim.DiffuseRows"/>.
    /// </summary>
    public static void DiffuseRows(Sim s, int y0, int y1, bool portable)
    {
        if (!portable && WideAvailable) { Wide(s, y0, y1); return; }
        if (PortableAvailable) { Portable(s, y0, y1); return; }
        s.DiffuseRows(y0, y1);
    }

    private static void Portable(Sim s, int y0, int y1)
    {
        int w = s.Cfg.Width, log2w = s.Log2W, xmask = s.XMask, ymask = s.YMask;
        float decay = s.Cfg.Decay;
        float[] src = s.Grid, dst = s.Scratch;
        int vw = Vector<float>.Count;
        ref float rs = ref MemoryMarshal.GetArrayDataReference(src);
        ref float rd = ref MemoryMarshal.GetArrayDataReference(dst);

        var vfour = new Vector<float>(4.0f);
        var vtwelve = new Vector<float>(12.0f);
        var vdecay = new Vector<float>(decay);

        for (int y = y0; y < y1; y++)
        {
            int rowm = ((y - 1) & ymask) << log2w;
            int row0 = y << log2w;
            int rowp = ((y + 1) & ymask) << log2w;

            Cell(src, dst, 0, rowm, row0, rowp, xmask, decay);

            int x = 1;
            for (; x + vw <= w - 1; x += vw)
            {
                var acc = Vector.LoadUnsafe(ref rs, (nuint)(rowm + x - 1));
                acc += Vector.LoadUnsafe(ref rs, (nuint)(rowm + x));
                acc += Vector.LoadUnsafe(ref rs, (nuint)(rowm + x + 1));
                acc += Vector.LoadUnsafe(ref rs, (nuint)(row0 + x - 1));
                acc += vfour * Vector.LoadUnsafe(ref rs, (nuint)(row0 + x));
                acc += Vector.LoadUnsafe(ref rs, (nuint)(row0 + x + 1));
                acc += Vector.LoadUnsafe(ref rs, (nuint)(rowp + x - 1));
                acc += Vector.LoadUnsafe(ref rs, (nuint)(rowp + x));
                acc += Vector.LoadUnsafe(ref rs, (nuint)(rowp + x + 1));
                (acc / vtwelve * vdecay).StoreUnsafe(ref rd, (nuint)(row0 + x));
            }

            for (; x < w; x++)
                Cell(src, dst, x, rowm, row0, rowp, xmask, decay);
        }
    }

    private static void Wide(Sim s, int y0, int y1)
    {
        int w = s.Cfg.Width, log2w = s.Log2W, xmask = s.XMask, ymask = s.YMask;
        float decay = s.Cfg.Decay;
        float[] src = s.Grid, dst = s.Scratch;
        int vw = Vector512<float>.Count;
        ref float rs = ref MemoryMarshal.GetArrayDataReference(src);
        ref float rd = ref MemoryMarshal.GetArrayDataReference(dst);

        var vfour = Vector512.Create(4.0f);
        var vtwelve = Vector512.Create(12.0f);
        var vdecay = Vector512.Create(decay);

        for (int y = y0; y < y1; y++)
        {
            int rowm = ((y - 1) & ymask) << log2w;
            int row0 = y << log2w;
            int rowp = ((y + 1) & ymask) << log2w;

            Cell(src, dst, 0, rowm, row0, rowp, xmask, decay);

            int x = 1;
            for (; x + vw <= w - 1; x += vw)
            {
                var acc = Vector512.LoadUnsafe(ref rs, (nuint)(rowm + x - 1));
                acc += Vector512.LoadUnsafe(ref rs, (nuint)(rowm + x));
                acc += Vector512.LoadUnsafe(ref rs, (nuint)(rowm + x + 1));
                acc += Vector512.LoadUnsafe(ref rs, (nuint)(row0 + x - 1));
                acc += vfour * Vector512.LoadUnsafe(ref rs, (nuint)(row0 + x));
                acc += Vector512.LoadUnsafe(ref rs, (nuint)(row0 + x + 1));
                acc += Vector512.LoadUnsafe(ref rs, (nuint)(rowp + x - 1));
                acc += Vector512.LoadUnsafe(ref rs, (nuint)(rowp + x));
                acc += Vector512.LoadUnsafe(ref rs, (nuint)(rowp + x + 1));
                (acc / vtwelve * vdecay).StoreUnsafe(ref rd, (nuint)(row0 + x));
            }

            for (; x < w; x++)
                Cell(src, dst, x, rowm, row0, rowp, xmask, decay);
        }
    }

    /// <summary>One output cell, scalar; used for the two wrapping columns.</summary>
    [MethodImpl(MethodImplOptions.AggressiveInlining)]
    private static void Cell(float[] src, float[] dst, int x,
                             int rowm, int row0, int rowp, int xmask, float decay)
    {
        int xm = (x - 1) & xmask;
        int xp = (x + 1) & xmask;
        float acc = src[rowm | xm];
        acc += src[rowm | x];
        acc += src[rowm | xp];
        acc += src[row0 | xm];
        acc += 4.0f * src[row0 | x];
        acc += src[row0 | xp];
        acc += src[rowp | xm];
        acc += src[rowp | x];
        acc += src[rowp | xp];
        dst[row0 | x] = acc / 12.0f * decay;
    }
}
