# Concept Graph — a native macOS window that agents feed with JSON.
#
#   make            build the viewer into skill/bin/
#   make check      build, then run the smoke tests
#   make install    make the skill available to Claude Code in every project
#   make uninstall  undo that
#   make clean      remove build output

SKILLS_DIR := $(HOME)/.claude/skills
LINK := $(SKILLS_DIR)/concept-graph

.PHONY: build check install uninstall clean

build:
	./scripts/build.sh

check: build
	./scripts/check.sh

install: build
	mkdir -p "$(SKILLS_DIR)"
	ln -sfn "$(CURDIR)/skill" "$(LINK)"
	@echo "installed: $(LINK) -> $(CURDIR)/skill"

uninstall:
	@if [ -L "$(LINK)" ]; then rm "$(LINK)" && echo "removed $(LINK)"; else echo "nothing to remove at $(LINK)"; fi

clean:
	rm -rf .build skill/bin
