/-
  Why the `binned` reduction is bit-identical to the serial run.

  SPEC-1 section 5.6 claims that the spatially binned parallel deposit produces
  exactly the same grid as the single-threaded run, at every thread count.
  Everything else in this project checks that claim by running it and comparing
  a hash -- which is evidence, not proof, and covers only the configurations
  someone thought to run.

  This file proves it.

  # Why floating point never appears

  The obvious way to state "bit-identical" is as an equation between two
  floating-point results, and in Lean that is not provable at all: `Float32` is
  an opaque type whose operations are `@[extern]` calls into the runtime, so
  the kernel has no axioms about them and cannot know that `a + b = b + a`
  fails, let alone anything finer.

  It is also not what the claim rests on. Deposits into one cell are applied by
  folding one operation over a list, and two folds of the *same* operation over
  the *same* list in the *same* order agree for any operation whatsoever --
  associativity, commutativity and rounding are all irrelevant. So the thing to
  prove is that the binned schedule and the serial schedule produce the same
  ordered list of deposits per cell. That is a statement about lists of natural
  numbers, it needs no arithmetic axioms, and `binned_cell_value_eq` below
  turns it back into a statement about the value in a cell for an arbitrary
  operation -- f32 addition among them.

  # What is assumed

  Two hypotheses, and both correspond to a line of the implementation:

  * The worker partition is a list of agent blocks whose concatenation is the
    serial order. `split()` in impl/c and every port that copies it produces
    contiguous, increasing ranges, which is exactly this. The C source calls
    the choice "identical to the C reference's, deliberately"; this file is
    what that deliberateness buys.
  * A cell's bucket depends only on the cell. In the implementation the bucket
    is `ybucket[idx >> log2w]`, a function of the row, hence of the cell.

  Nothing else is assumed. In particular the number of workers, the block
  sizes, the number of agents and which cell each agent lands in are all
  arbitrary -- so the theorem covers thread counts and inputs no test ever ran.
-/

namespace Slimebench.Proofs

/-- A grid cell, identified by its linear index. -/
abbrev Cell := Nat

/-- An agent, identified by its index. Agent order *is* index order: SPEC-1
    5.3 applies the agent pass in ascending index. -/
abbrev Agent := Nat

/--
The order in which the single-threaded run applies deposits.

`chunks` is the worker partition in worker order. Its concatenation is the
serial order -- that is what "contiguous, increasing ranges" means, and it is
the only property of the partition this file uses.
-/
def serialOrder (chunks : List (List Agent)) : List Agent := chunks.flatten

/--
The order in which the binned reduction applies them: bucket-major, then
worker, then agent index within the worker.

This mirrors the four phases of the implementation. `prefixBinned` lays the
sorted array out bucket by bucket and, within a bucket, worker by worker;
`scatterBinned` fills each worker's slice in ascending agent index;
`depositBinned` then has worker `b` walk the slice belonging to bucket `b` in
order. The composition of those three is this expression.
-/
def binnedOrder (T : Nat) (bucket : Cell → Nat) (cellOf : Agent → Cell)
    (chunks : List (List Agent)) : List Agent :=
  (List.range T).flatMap fun b =>
    chunks.flatMap fun ch => ch.filter fun i => bucket (cellOf i) == b

/-- The deposits landing in one cell, in the order they are applied to it. -/
def depositsInto (cellOf : Agent → Cell) (c : Cell) (order : List Agent) :
    List Agent :=
  order.filter fun i => cellOf i == c

/- ---- two small list lemmas ---------------------------------------------- -/

/-- A guarded flatMap contributes nothing where the guard never fires. -/
private theorem flatMap_ite_nil {α : Type _} (l : List Nat) (k : Nat)
    (X : Nat → List α) (h : ∀ b ∈ l, b ≠ k) :
    (l.flatMap fun b => if b = k then X b else []) = [] := by
  induction l with
  | nil => rfl
  | cons a t ih =>
    have ha : a ≠ k := h a (by simp)
    have ht : ∀ b ∈ t, b ≠ k := fun b hb => h b (by simp [hb])
    simp [List.flatMap_cons, if_neg ha, ih ht]

/-- Selecting one index out of `range T` with a guarded flatMap. -/
private theorem flatMap_range_ite {α : Type _} (T k : Nat) (X : Nat → List α)
    (hk : k < T) :
    ((List.range T).flatMap fun b => if b = k then X b else []) = X k := by
  induction T with
  | zero => omega
  | succ n ih =>
    rw [List.range_succ, List.flatMap_append]
    rcases Nat.lt_or_ge k n with h | h
    · -- k is inside range n; the singleton tail cannot match it
      have hne : n ≠ k := by omega
      simp [ih h, List.flatMap_cons, if_neg hne]
    · -- k = n; range n contains only indices below k
      have hkn : k = n := by omega
      subst hkn
      have : ∀ b ∈ List.range k, b ≠ k := by
        intro b hb
        have := List.mem_range.mp hb
        omega
      simp [flatMap_ite_nil _ _ _ this, List.flatMap_cons]

/- ---- the theorem --------------------------------------------------------- -/

/--
**The binned schedule applies each cell's deposits in the serial order.**

For every cell, the list of agents depositing into it under the binned
reduction is *the same list, in the same order* as under the single-threaded
run — for any number of workers, any partition of the agents into worker
blocks, and any assignment of agents to cells.

The proof is short because the structure does the work. Filtering by cell
commutes with both flatMaps; inside, the bucket test and the cell test
collapse, because an agent that passes the cell test has a known cell and
therefore a known bucket. Only the one bucket owning `c` survives the outer
loop, and what is left of the inner one is the serial order filtered by cell.
-/
theorem binned_deposits_eq_serial
    (T : Nat) (bucket : Cell → Nat) (cellOf : Agent → Cell)
    (chunks : List (List Agent)) (c : Cell) (hc : bucket c < T) :
    depositsInto cellOf c (binnedOrder T bucket cellOf chunks)
      = depositsInto cellOf c (serialOrder chunks) := by
  unfold depositsInto binnedOrder serialOrder
  -- Inside one worker block, the bucket test and the cell test fuse. An agent
  -- that passes the cell test has cell `c`, hence bucket `bucket c`, so the
  -- bucket test is decided by `b` alone.
  have inner_pos : ∀ ch : List Agent,
      ((ch.filter fun i => bucket (cellOf i) == bucket c).filter
        fun i => cellOf i == c)
      = ch.filter (fun i => cellOf i == c) := by
    intro ch
    rw [List.filter_filter]
    apply List.filter_congr
    intro i _
    by_cases hi : cellOf i = c <;> simp [hi]
  have inner_neg : ∀ (b : Nat), b ≠ bucket c → ∀ ch : List Agent,
      ((ch.filter fun i => bucket (cellOf i) == b).filter
        fun i => cellOf i == c) = [] := by
    intro b hb ch
    rw [List.filter_filter, List.filter_eq_nil_iff]
    intro i _
    simp only [Bool.and_eq_true, beq_iff_eq, not_and]
    intro hci hbi
    -- hci : cellOf i = c, hbi : bucket (cellOf i) = b
    exact hb (hci ▸ hbi).symm
  -- `chunks.flatten.filter p` and `chunks.flatMap (·.filter p)` are the same
  -- list; the second shape is the one the outer loop produces.
  have flat : ∀ p : Agent → Bool,
      chunks.flatten.filter p = chunks.flatMap (fun ch => ch.filter p) := by
    intro p
    rw [List.flatten_eq_flatMap, List.filter_flatMap]
    simp
  -- One bucket at a time.
  have step : ∀ b : Nat,
      ((chunks.flatMap fun ch => ch.filter fun i => bucket (cellOf i) == b).filter
        fun i => cellOf i == c)
      = if b = bucket c then chunks.flatten.filter (fun i => cellOf i == c)
        else [] := by
    intro b
    rw [List.filter_flatMap]
    by_cases h : b = bucket c
    · subst h
      simp only [inner_pos]
      exact (flat _).symm
    · simp only [if_neg h, inner_neg b h]
      induction chunks with
      | nil => rfl
      | cons a t ih => simp [List.flatMap_cons]
  rw [List.filter_flatMap]
  simp only [step]
  exact flatMap_range_ite T (bucket c) _ hc

/--
**Therefore every cell ends with the same value.**

`f` is an arbitrary binary operation. The benchmark's is `fun acc _ => acc + d`
in `Float32`, but nothing here knows or needs that: the two folds run over the
same list in the same order, so they agree whatever `f` does. This is where
the floating point that Lean cannot reason about re-enters, as something the
theorem never had to look inside.
-/
theorem binned_cell_value_eq {β : Type _}
    (T : Nat) (bucket : Cell → Nat) (cellOf : Agent → Cell)
    (chunks : List (List Agent)) (c : Cell) (hc : bucket c < T)
    (f : β → Agent → β) (init : β) :
    (depositsInto cellOf c (binnedOrder T bucket cellOf chunks)).foldl f init
      = (depositsInto cellOf c (serialOrder chunks)).foldl f init := by
  rw [binned_deposits_eq_serial T bucket cellOf chunks c hc]

/--
The same statement one step closer to the code: the grid is a function from
cells to values, the deposit is a constant, and both schedules produce the same
grid.
-/
theorem binned_grid_eq {β : Type _}
    (T : Nat) (bucket : Cell → Nat) (cellOf : Agent → Cell)
    (chunks : List (List Agent)) (hT : ∀ c : Cell, bucket c < T)
    (add : β → β → β) (deposit : β) (grid₀ : Cell → β) :
    (fun c => (depositsInto cellOf c (binnedOrder T bucket cellOf chunks)).foldl
                (fun acc _ => add acc deposit) (grid₀ c))
      = (fun c => (depositsInto cellOf c (serialOrder chunks)).foldl
                (fun acc _ => add acc deposit) (grid₀ c)) := by
  funext c
  exact binned_cell_value_eq T bucket cellOf chunks c (hT c) _ _

/- ---- what the proof rests on -------------------------------------------

   A theorem is only as good as the axioms under it, and a `sorry` anywhere
   would be invisible in a build log. These print the full axiom set; anything
   beyond the three standard ones -- and `sorryAx` in particular -- is a
   failure, and `lake build Proofs` surfaces it because #print axioms is
   evaluated at elaboration time. -/

#print axioms binned_deposits_eq_serial
#print axioms binned_cell_value_eq
#print axioms binned_grid_eq

end Slimebench.Proofs
