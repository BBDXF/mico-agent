# Native build:   make
# Cross build:    make CROSS=arm-linux-gnueabihf- [SYSROOT=/path/to/sysroot]
# Release bundle: make [CROSS=...] dist  -> build/mico-agent-<version>-<arch>.tar.gz
CROSS    ?=
CC       := $(CROSS)gcc
CXX      := $(CROSS)g++
STRIP    := $(CROSS)strip
BUILD    ?= build

OPT      ?= -Os
VERSION  ?= $(shell git describe --tags 2>/dev/null | sed 's/^v//' || true)
ifeq ($(strip $(VERSION)),)
VERSION  := 0.2.0
endif
MICO_VERSION ?= $(VERSION)
ARCH     ?= $(shell $(CC) -dumpmachine 2>/dev/null | cut -d- -f1)
ifneq ($(SYSROOT),)
CFLAGS   += --sysroot=$(SYSROOT)
CXXFLAGS += --sysroot=$(SYSROOT)
LDFLAGS  += --sysroot=$(SYSROOT)
endif
GIT_REV  := $(shell git rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_TS := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
CFLAGS   += $(OPT) -Wall -DLUA_USE_POSIX
CXXFLAGS += $(OPT) -std=c++14 -Wall -Wextra -Ithird_party -Ithird_party/lua/src \
            -ffunction-sections -fdata-sections \
            -DMICO_VERSION='"$(MICO_VERSION)"' -DMICO_GIT='"$(GIT_REV)"' -DMICO_BUILD_TIME='"$(BUILD_TS)"'
LDFLAGS  += -Wl,--gc-sections
LDLIBS   += -lcurl -lm

LUA_SRC  := $(filter-out %/lua.c %/luac.c %/print.c,$(wildcard third_party/lua/src/*.c))
LUA_OBJ  := $(LUA_SRC:third_party/lua/src/%.c=$(BUILD)/lua/%.o)
CORE_SRC := src/http.cpp src/llm.cpp src/instruction.cpp src/tail.cpp src/runtime.cpp src/fuzzy.cpp src/sys.cpp src/httpd.cpp src/saver.cpp src/logger.cpp
CORE_OBJ := $(CORE_SRC:src/%.cpp=$(BUILD)/%.o)

.PHONY: all test clean dist
all: $(BUILD)/mico-agent

$(BUILD)/mico-agent: $(BUILD)/main.o $(CORE_OBJ) $(LUA_OBJ)
	$(CXX) $(LDFLAGS) -o $@ $^ $(LDLIBS)
	$(STRIP) -o $@.stripped $@

$(BUILD)/unit_test: $(BUILD)/tests/unit_test.o $(CORE_OBJ) $(LUA_OBJ)
	$(CXX) $(LDFLAGS) -o $@ $^ $(LDLIBS)

$(BUILD)/lua/%.o: third_party/lua/src/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -w -c -o $@ $<

$(BUILD)/%.o: src/%.cpp src/*.h src/*.inc
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c -o $@ $<

$(BUILD)/tests/%.o: tests/%.cpp src/*.h
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -Isrc -c -o $@ $<

test: $(BUILD)/unit_test $(BUILD)/mico-agent
	$(BUILD)/unit_test
	python3 tests/integration_test.py $(BUILD)/mico-agent

DIST_NAME := mico-agent-$(VERSION)-$(ARCH)
DIST_DIR  := $(BUILD)/dist/$(DIST_NAME)
dist: $(BUILD)/mico-agent
	rm -rf $(DIST_DIR)
	mkdir -p $(DIST_DIR)
	cp $(BUILD)/mico-agent.stripped $(DIST_DIR)/mico-agent
	mkdir -p $(DIST_DIR)/scripts
	cp -r scripts/lib scripts/plugins scripts/tools scripts/web scripts/main.lua $(DIST_DIR)/scripts/
	cp config.example.json README.md $(DIST_DIR)/
	if [ -f LICENSE ]; then cp LICENSE $(DIST_DIR)/; fi
	tar -C $(BUILD)/dist -czf $(BUILD)/$(DIST_NAME).tar.gz $(DIST_NAME)
	@echo "dist: $(BUILD)/$(DIST_NAME).tar.gz"

clean:
	rm -rf $(BUILD)
