# Memory Index

- [memory.init / data.drop implementation](project_memory_init_datadrop.md) — Implementation details, spec behavior, and test results for bulk memory operations
- [Conversion instructions implementation](project_conversion_instructions.md) — Trunc/convert/reinterpret spec boundaries; conversions: pass=619 skip=0 fail=0
- [memory.size / table.size/grow/fill / ref.* implementation](project_memory_size_table_ops_ref.md) — memory.grow max-page fix; ref.null/is_null/func; table ops with max-limit enforcement
- [Cross-module linking / funcref globals / expression-based element segments](project_cross_module_funcref_elements.md) — register command, funcref global init (ref.func/ref.null), element flags 3-7; table_copy skip=1117→0
- [externref / parser validation improvements](project_externref_parser_validation.md) — externref Value case, tables [[Value]], UTF-8 custom section, LEB128 canonical, trailing bytes
- [Binary parser validation improvements](project_binary_parser_validation.md) — section ordering, duplicates, size mismatch, data count, reftype; binary pass=127 skip=0
