CC ?= gcc
CFLAGS ?= -O2 -g -Wall -Wextra -Werror
SANFLAGS ?= -fsanitize=address,undefined

HEADERS = ../../src/fde-boot-loader.h
SOURCES = test_boot_loader.c ../../src/fde-boot-loader-parse.c
TARGET = test_boot_loader

FUZZ_TARGET = fuzz_boot_loader
FUZZ_SOURCES = fuzz_boot_loader.c ../../src/fde-boot-loader-parse.c

# Probe if CC supports -fsanitize=fuzzer (Clang) or needs standalone driver (GCC)
HAS_FUZZER := $(shell $(CC) -fsanitize=fuzzer -x c /dev/null -E >/dev/null 2>&1 && echo yes || echo no)

ifeq ($(HAS_FUZZER),yes)
FUZZ_FLAGS ?= -fsanitize=fuzzer,address,undefined
else
FUZZ_FLAGS ?= -fsanitize=address,undefined -DSTANDALONE_FUZZER
endif

.PHONY: all check clean fuzz check-fuzz

all: $(TARGET)

$(TARGET): $(SOURCES) $(HEADERS)
	$(CC) $(CFLAGS) $(SANFLAGS) -I../../src -o $@ $(SOURCES)

check: $(TARGET)
	./$(TARGET) ../fixtures/bootopt

fuzz $(FUZZ_TARGET): $(FUZZ_SOURCES) $(HEADERS)
	$(CC) $(CFLAGS) $(FUZZ_FLAGS) -I../../src -o $(FUZZ_TARGET) $(FUZZ_SOURCES)

check-fuzz: $(FUZZ_TARGET)
	@tmpcorpus=$$(mktemp -d /tmp/fde_fuzz_corpus.XXXXXX); \
	cp -a ../fixtures/bootopt/*.bin "$$tmpcorpus/"; \
	trap 'rm -rf "$$tmpcorpus"' EXIT INT TERM; \
	if [ "$(HAS_FUZZER)" = "yes" ]; then \
		echo "Running LibFuzzer (30s time limit)..."; \
		./$(FUZZ_TARGET) -max_total_time=30 "$$tmpcorpus"; \
	else \
		echo "Running standalone fuzzer over fixture corpus..."; \
		./$(FUZZ_TARGET) "$$tmpcorpus"/*; \
	fi

clean:
	rm -f $(TARGET) $(FUZZ_TARGET) *.o
