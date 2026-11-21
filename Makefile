# Concept Graph — a native macOS window that agents feed with JSON.
#
#   make            build the viewer into skill/bin/
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

.PHONY: build check install uninstall clean demo help

build:
	./scripts/build.sh

help:
	@echo "make demo                  Open a working copy of the system-design example"
	@echo "make install               Install for Claude Code across projects"
	@echo "make install AGENT=codex   Install for Codex across projects"
	@echo "make uninstall             Remove the link (use the same agent selection)"
	@echo "make                       Build the viewer after updating the checkout"
	@echo "make check                 Build and run the checks"

demo:
	@set -e; dir=$$(mktemp -d "$${TMPDIR:-/tmp}/concept-graph.XXXXXX"); \
	cp skill/examples/report-delivery.json "$$dir/report-delivery.json"; \
	./skill/scripts/concept-graph open "$$dir/report-delivery.json"

check: build
	./scripts/check.sh

install: build
	mkdir -p "$(SKILLS_DIR)"
	@if [ -L "$(LINK)" ] && [ "$$(readlink "$(LINK)")" = "$(CURDIR)/skill" ]; then :; \
	elif [ -e "$(LINK)" ] || [ -L "$(LINK)" ]; then echo "Already occupied: $(LINK)" >&2; exit 1; \
	else ln -s "$(CURDIR)/skill" "$(LINK)"; fi
	@echo "installed: $(LINK) -> $(CURDIR)/skill"

uninstall:
	@if [ -L "$(LINK)" ] && [ "$$(readlink "$(LINK)")" = "$(CURDIR)/skill" ]; then rm "$(LINK)" && echo "removed $(LINK)"; else echo "nothing to remove at $(LINK)"; fi

clean:
	rm -rf .build skill/bin
