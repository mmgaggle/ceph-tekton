# Round 1 example for the reproducibility-check harness.
#
# `make broken` produces a binary that embeds the wall-clock time
# (__DATE__ / __TIME__). Two invocations one second apart produce
# byte-different `hello-broken` binaries — exactly the kind of finding
# the diffoscope harness should surface.
#
# `make fixed` produces the same program but rewrites the date/time
# macros from SOURCE_DATE_EPOCH, so two builds at different wall times
# produce byte-identical `hello-fixed` binaries.
#
# Both targets also pass `-ffile-prefix-map=$(PWD)=.` to strip the
# build-host absolute path from the DWARF debug info — without this,
# two builds done in different working directories would diverge even
# if the timestamp problem were fixed.
#
# Usage from the reproducibility-check Task:
#   build-command: "cd tasks/reproducibility-check/examples/timestamps && make broken"
#   output-glob:   "tasks/reproducibility-check/examples/timestamps/hello-broken"
#
# Local dev loop (no Tekton):
#   make demo-broken   # prove non-reproducibility — sha256 differs
#   make demo-fixed    # prove the fix — sha256 matches

CC      ?= gcc
CFLAGS  ?= -O2 -g
# Strip $PWD from DWARF debug info regardless of broken/fixed.
CFLAGS  += -ffile-prefix-map=$(PWD)=.

# SOURCE_DATE_EPOCH wiring for the fixed target. Falls back to a fixed
# constant (2024-01-01 UTC) if the env var is unset so the example is
# self-contained.
SOURCE_DATE_EPOCH ?= 1704067200
EPOCH_DATE := $(shell date -u -r $(SOURCE_DATE_EPOCH) "+%b %d %Y" 2>/dev/null || date -u -d @$(SOURCE_DATE_EPOCH) "+%b %d %Y")
EPOCH_TIME := $(shell date -u -r $(SOURCE_DATE_EPOCH) "+%H:%M:%S" 2>/dev/null || date -u -d @$(SOURCE_DATE_EPOCH) "+%H:%M:%S")

.PHONY: all broken fixed demo-broken demo-fixed clean

all: broken fixed

# Round 1 — broken: relies on the preprocessor's wall-clock __DATE__/__TIME__.
broken: hello-broken
hello-broken: hello.c
	$(CC) $(CFLAGS) -o $@ $<

# Round 1 — fixed: override the macros from SOURCE_DATE_EPOCH.
# `-Wno-builtin-macro-redefined` silences gcc's warning about
# overriding builtin macros; without it the build fails under -Werror.
fixed: hello-fixed
hello-fixed: hello.c
	$(CC) $(CFLAGS) \
	    -Wno-builtin-macro-redefined \
	    -D'__DATE__="$(EPOCH_DATE)"' \
	    -D'__TIME__="$(EPOCH_TIME)"' \
	    -o $@ $<

# Local demo helpers — prove the (non-)reproducibility without needing
# Tekton or diffoscope. The harness automates this; these are for
# eyeball iteration on a laptop.
demo-broken: clean
	@$(MAKE) -s broken
	@sha1=$$(shasum -a 256 hello-broken | awk '{print $$1}'); \
	    sleep 1; \
	    rm hello-broken; \
	    $(MAKE) -s broken; \
	    sha2=$$(shasum -a 256 hello-broken | awk '{print $$1}'); \
	    echo "build A sha256: $$sha1"; \
	    echo "build B sha256: $$sha2"; \
	    [ "$$sha1" = "$$sha2" ] && echo "REPRODUCIBLE" || echo "NON-REPRODUCIBLE (expected)"

demo-fixed: clean
	@$(MAKE) -s fixed
	@sha1=$$(shasum -a 256 hello-fixed | awk '{print $$1}'); \
	    sleep 1; \
	    rm hello-fixed; \
	    $(MAKE) -s fixed; \
	    sha2=$$(shasum -a 256 hello-fixed | awk '{print $$1}'); \
	    echo "build A sha256: $$sha1"; \
	    echo "build B sha256: $$sha2"; \
	    [ "$$sha1" = "$$sha2" ] && echo "REPRODUCIBLE (expected)" || echo "NON-REPRODUCIBLE"

clean:
	rm -f hello-broken hello-fixed
