# Concept Graph — portable graph documents and a native macOS viewer.
#
#   make            build the platform CLI into skill/bin/
#   make check      build, then run the smoke tests
#   make install    make the skill available to Claude Code in every project
#   make uninstall  undo that
#   make clean      remove build output

AGENT ?= claude
ifeq ($(AGENT),claude)
SKILLS_DIR ?= $(HOME)/.claude/skills
else ifeq ($(AGENT),codex)
SKILLS_DIR ?= $(HOME)/.agents/skills
else ifndef SKILLS_DIR
$(error Use AGENT=claude, AGENT=codex, or set SKILLS_DIR)
endif
LINK := $(SKILLS_DIR)/concept-graph

.PHONY: build check install install-skill uninstall clean demo help

build:
	./scripts/build.sh

help:
	@echo "make demo                  Open a working copy of the system-design example"
	@echo "make install               Install for Claude Code across projects"
	@echo "make install AGENT=codex   Install for Codex across projects"
	@echo "make install-skill         Link the authoring skill without building the CLI"
	@echo "make uninstall             Remove the link (use the same agent selection)"
	@echo "make                       Build the CLI (includes the viewer on macOS)"
	@echo "make check                 Test document handoff and, on macOS, the viewer"
	@echo "make check-windows         Test a disposable graph window on this desktop"
	@echo "make check-build           Test first builds and failed rebuilds in a temporary checkout"
	@echo "make benchmark             Measure offscreen first frames, reloads and drags"

demo:
	@set -e; dir=$$(mktemp -d "$${TMPDIR:-/tmp}/concept-graph.XXXXXX"); \
	cp skill/examples/report-delivery.json "$$dir/report-delivery.json"; \
	./skill/scripts/concept-graph open "$$dir/report-delivery.json"

check: build
	./scripts/check-authoring.sh
ifeq ($(shell uname -s),Darwin)
	./scripts/check.sh
	./scripts/check-canvas.sh
endif

install: build
install install-skill:
	mkdir -p "$(SKILLS_DIR)"
	@if [ -L "$(LINK)" ] && [ "$$(readlink "$(LINK)")" = "$(CURDIR)/skill" ]; then :; \
	elif [ -e "$(LINK)" ] || [ -L "$(LINK)" ]; then echo "Already occupied: $(LINK)" >&2; exit 1; \
	else ln -s "$(CURDIR)/skill" "$(LINK)"; fi
	@echo "installed: $(LINK) -> $(CURDIR)/skill"

uninstall:
	@if [ -L "$(LINK)" ] && [ "$$(readlink "$(LINK)")" = "$(CURDIR)/skill" ]; then rm "$(LINK)" && echo "removed $(LINK)"; else echo "nothing to remove at $(LINK)"; fi

clean:
	rm -rf .build skill/bin

.PHONY: check-windows benchmark
check-windows: build
	./scripts/check-windows.sh

benchmark:
	./scripts/check-canvas.sh --benchmark

.PHONY: check-build
check-build:
	./scripts/check-build.sh
