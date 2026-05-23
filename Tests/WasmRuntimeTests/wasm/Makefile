WAT_SRCS  := $(wildcard *.wat)
WASM_BINS := $(WAT_SRCS:.wat=.wasm)

.PHONY: all clean

all: $(WASM_BINS)

%.wasm: %.wat
	wat2wasm $< -o $@
	@echo "✓ $< → $@"

clean:
	rm -f $(WASM_BINS)
