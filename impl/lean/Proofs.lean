/-
  Machine-checked parts of SPEC-1.

  Two claims the spec makes, that every implementation depends on, and that
  nothing else in this project verifies except by running it and comparing a
  hash:

    Binned  the spatially binned parallel deposit applies each cell's deposits
            in exactly the serial order, at any thread count and any partition
    Index   the bit-masked torus index is the modulo index, stays inside the
            grid, and is injective

  Neither proof mentions floating point, and that is deliberate rather than a
  limitation -- see the header of Proofs/Binned.lean.

  `lake build Proofs` checks them. Each file ends in `#print axioms`, so a
  `sorry` anywhere would show up in the build output rather than passing
  quietly.
-/

import Proofs.Binned
import Proofs.Index
