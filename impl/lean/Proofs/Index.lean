/-
  Why the bit-masked torus index is the modulo index.

  Every port computes a cell index the same way (SPEC-1 section 2.2):

      idx = ((y &&& ymask) <<< log2w) ||| (x &&& xmask)

  with `xmask = 2^log2w - 1` and `ymask = 2^log2h - 1`. The spec asserts this
  is the wrap-around index `(y mod h) * w + (x mod w)`, and that the grid may
  therefore be addressed without a division and the deposit written without a
  bounds check. Nothing in the project checks that assertion; it is
  load-bearing for all fourteen implementations and for the assembly kernel,
  where the entire torus wrap collapses into one `AND`.

  This file proves it, for every power-of-two grid and every coordinate.
-/

namespace Slimebench.Proofs

/--
Shifting and or-ing is adding, when the low part fits.

Core has no such lemma, so this goes through bit extensionality: above the
shift the low part contributes no bits, below it the high part contributes
none, and the two sides agree bit by bit.
-/
private theorem shiftLeft_or_eq_add (a b k : Nat) (hb : b < 2 ^ k) :
    (a <<< k) ||| b = a * 2 ^ k + b := by
  rw [Nat.shiftLeft_eq]
  have hcomm : a * 2 ^ k + b = 2 ^ k * a + b := by rw [Nat.mul_comm]
  have hmod : (a * 2 ^ k + b) % 2 ^ k = b := by
    rw [hcomm, Nat.mul_add_mod, Nat.mod_eq_of_lt hb]
  have hdiv : (a * 2 ^ k + b) / 2 ^ k = a := by
    rw [hcomm, Nat.mul_add_div (Nat.two_pow_pos k), Nat.div_eq_of_lt hb, Nat.add_zero]
  apply Nat.eq_of_testBit_eq
  intro i
  rw [Nat.testBit_or, Nat.testBit_mul_two_pow]
  rcases Nat.lt_or_ge i k with h | h
  · -- Below the shift: only `b` has bits here, on both sides.
    have hik : ¬ (k ≤ i) := by omega
    have key : ((a * 2 ^ k + b) % 2 ^ k).testBit i = (a * 2 ^ k + b).testBit i := by
      rw [Nat.testBit_mod_two_pow]; simp [h]
    rw [hmod] at key
    simp [hik, key]
  · -- At or above the shift: only `a` does.
    obtain ⟨j, rfl⟩ : ∃ j, i = k + j := ⟨i - k, by omega⟩
    have hbz : b.testBit (k + j) = false :=
      Nat.testBit_lt_two_pow
        (Nat.lt_of_lt_of_le hb (Nat.pow_le_pow_right (by omega) (by omega)))
    have hr : (a * 2 ^ k + b).testBit (k + j) = a.testBit j := by
      rw [Nat.add_comm k j, Nat.testBit_add, hdiv]
    simp [hbz, hr]

/-- Splitting an index back into its coordinates, which is what makes the
    masked form invertible. -/
private theorem div_mod_of_lt (u v m : Nat) (hm : 0 < m) (hv : v < m) :
    (u * m + v) / m = u ∧ (u * m + v) % m = v := by
  constructor
  · rw [Nat.mul_comm, Nat.mul_add_div hm, Nat.div_eq_of_lt hv, Nat.add_zero]
  · rw [Nat.mul_comm, Nat.mul_add_mod, Nat.mod_eq_of_lt hv]

/--
**The bit-masked index is the modulo index.**

`log2w` and `log2h` are the grid's exponents, so `w = 2^log2w` and
`h = 2^log2h`; `x` and `y` are arbitrary, so this covers the wrapped case as
well as the in-range one.
-/
theorem masked_index_eq_mod (log2w log2h x y : Nat) :
    (((y &&& (2 ^ log2h - 1)) <<< log2w) ||| (x &&& (2 ^ log2w - 1)))
      = (y % 2 ^ log2h) * 2 ^ log2w + (x % 2 ^ log2w) := by
  rw [Nat.and_two_pow_sub_one_eq_mod, Nat.and_two_pow_sub_one_eq_mod]
  exact shiftLeft_or_eq_add _ _ _ (Nat.mod_lt _ (Nat.two_pow_pos log2w))

/--
**And it always lands inside the grid.**

The other half of what the ports rely on: the deposit needs no bounds check,
because masking makes an out-of-range index impossible rather than merely
unlikely.
-/
theorem masked_index_lt (log2w log2h x y : Nat) :
    (((y &&& (2 ^ log2h - 1)) <<< log2w) ||| (x &&& (2 ^ log2w - 1)))
      < 2 ^ log2h * 2 ^ log2w := by
  rw [masked_index_eq_mod]
  have hy : y % 2 ^ log2h < 2 ^ log2h := Nat.mod_lt _ (Nat.two_pow_pos log2h)
  have hx : x % 2 ^ log2w < 2 ^ log2w := Nat.mod_lt _ (Nat.two_pow_pos log2w)
  calc (y % 2 ^ log2h) * 2 ^ log2w + x % 2 ^ log2w
      < (y % 2 ^ log2h) * 2 ^ log2w + 2 ^ log2w := by omega
    _ = ((y % 2 ^ log2h) + 1) * 2 ^ log2w := by rw [Nat.add_one_mul]
    _ ≤ 2 ^ log2h * 2 ^ log2w := Nat.mul_le_mul_right _ (by omega)

/--
**Distinct cells get distinct indices.**

Injectivity over one grid's worth of coordinates. With the bound above, the
index map is a bijection onto `[0, w*h)` — which is what lets the grid be a
flat array and the checksum a linear scan over it.
-/
theorem masked_index_injective (log2w log2h x₁ y₁ x₂ y₂ : Nat)
    (hx₁ : x₁ < 2 ^ log2w) (hy₁ : y₁ < 2 ^ log2h)
    (hx₂ : x₂ < 2 ^ log2w) (hy₂ : y₂ < 2 ^ log2h)
    (h : (((y₁ &&& (2 ^ log2h - 1)) <<< log2w) ||| (x₁ &&& (2 ^ log2w - 1)))
       = (((y₂ &&& (2 ^ log2h - 1)) <<< log2w) ||| (x₂ &&& (2 ^ log2w - 1)))) :
    x₁ = x₂ ∧ y₁ = y₂ := by
  rw [masked_index_eq_mod, masked_index_eq_mod,
    Nat.mod_eq_of_lt hx₁, Nat.mod_eq_of_lt hy₁,
    Nat.mod_eq_of_lt hx₂, Nat.mod_eq_of_lt hy₂] at h
  obtain ⟨hd₁, hm₁⟩ := div_mod_of_lt y₁ x₁ _ (Nat.two_pow_pos log2w) hx₁
  obtain ⟨hd₂, hm₂⟩ := div_mod_of_lt y₂ x₂ _ (Nat.two_pow_pos log2w) hx₂
  exact ⟨by rw [← hm₁, ← hm₂, h], by rw [← hd₁, ← hd₂, h]⟩

/- ---- what the proofs rest on -------------------------------------------- -/

#print axioms masked_index_eq_mod
#print axioms masked_index_lt
#print axioms masked_index_injective

end Slimebench.Proofs
