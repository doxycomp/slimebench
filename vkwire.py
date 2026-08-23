import pathlib


def patch(rel, pairs):
    p = pathlib.Path(rel)
    s = p.read_text(encoding="utf-8")
    for a, b in pairs:
        assert a in s, f"NOT FOUND in {rel}:\n{a[:200]}"
        s = s.replace(a, b, 1)
    p.write_text(s, encoding="utf-8", newline="\n")
    print("patched", rel)


patch("bench/machine.sh", [
    ('''if [ -x "$GL" ]; then
  C_SAVE=$C; C=$GL
  run "gl 4.3 compute" --preset medium --ticks 100 --update deferred
  C=$C_SAVE
else
  emit "  gl 4.3 compute          not built"
fi''',
     '''if [ -x "$GL" ]; then
  C_SAVE=$C; C=$GL
  run "gl 4.3 compute" --preset medium --ticks 100 --update deferred
  C=$C_SAVE
else
  emit "  gl 4.3 compute          not built"
fi
# Vulkan by device kind rather than by index, and every kind the machine has:
# this is the row that makes the report about the computer rather than about
# one vendor's GPU.
VK=impl/vulkan/build/default/slimebench-vk
if [ -x "$VK" ]; then
  C_SAVE=$C; C=$VK
  for kind in discrete integrated cpu; do
    run "vulkan $kind" --preset medium --ticks 100 --update deferred \\
                       --device "$kind"
  done
  C=$C_SAVE
else
  emit "  vulkan                  not built"
fi'''),
])

patch("bench/full-run.sh", [
    ("--targets cuda,glcompute,pygl",
     "--targets cuda,glcompute,pygl,vulkan,vulkan-cpu"),
])
