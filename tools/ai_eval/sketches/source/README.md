# Assembly sketch sources

`asm_pin_block`, `asm_wheel_bracket_*` and `asm_caster_*` are drawn from reference models, not by hand, so their
answer keys come from a model rather than a reading of the drawing. `models.py` also models the owner's hand
sketches as read for their keys (`asm_block_pins` so far), so every assembly key comes from the same place.

```
$CAD_PY -I models.py out/                 # the backend's conda python (OpenCascade); writes out/views.json,
                                          # out/keys.json and out/step/*.step
cp out/keys.json ../../harness/assembly_keys.json
python draw.py out/views.json ..          # any python with matplotlib and Pillow; redraws the generated sheets
```

The sheets are A3, third-angle, saved at 1568 px on the long edge as the app downscales an attachment. Change a
part in `models.py`, rerun both, and the drawing, the key and the reference STEP all follow.
