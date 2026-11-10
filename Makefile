DOCS_DIR := docs
README := README.md
SECURITY := SECURITY.md
DOCS_OUTPUT := combined_docs.md
CODE_AND_TESTS_OUTPUT := combined_code_and_tests.txt
CODE_OUTPUT := combined_code.txt
TESTS_OUTPUT := combined_tests.txt
WEB_OUTPUT := combined_web.txt

.DEFAULT_GOAL := client

.PHONY: docs clean code_and_tests code tests test client web

client:

	@echo "Building Current CLI..."
	@mix escript.build
	@echo "Built ./current"

test:
	MIX_ENV=test mix test

tests:
	@echo "Generating $(TESTS_OUTPUT)..."
	@rm -f $(TESTS_OUTPUT)
	@for file in $$(find test -type f -name '*_test.exs' | sort); do \
		echo "# $$file" >> $(TESTS_OUTPUT); \
		echo "" >> $(TESTS_OUTPUT); \
		echo '```elixir' >> $(TESTS_OUTPUT); \
		cat $$file >> $(TESTS_OUTPUT); \
		echo "" >> $(TESTS_OUTPUT); \
		echo '```' >> $(TESTS_OUTPUT); \
		echo "" >> $(TESTS_OUTPUT); \
		echo "---" >> $(TESTS_OUTPUT); \
		echo "" >> $(TESTS_OUTPUT); \
	done
	@echo "Done."

code:
	@echo "Generating $(CODE_OUTPUT)..."
	@rm -f $(CODE_OUTPUT)
	@for file in $$(find lib README.md config -type f \( -name '*.ex' -o -name '*.exs' -o -name '*.md' \) | sort); do \
		echo "# $$file" >> $(CODE_OUTPUT); \
		echo "" >> $(CODE_OUTPUT); \
		echo '```elixir' >> $(CODE_OUTPUT); \
		cat $$file >> $(CODE_OUTPUT); \
		echo "" >> $(CODE_OUTPUT); \
		echo '```' >> $(CODE_OUTPUT); \
		echo "" >> $(CODE_OUTPUT); \
		echo "---" >> $(CODE_OUTPUT); \
		echo "" >> $(CODE_OUTPUT); \
	done
	@echo "Done."

code_and_tests:
	@echo "Generating $(CODE_AND_TESTS_OUTPUT)..."
	@rm -f $(CODE_AND_TESTS_OUTPUT)
	@for file in $$(find lib test config README.md -type f \( -name '*.ex' -o -name '*.exs' -o -name '*.md' \) | sort); do \
		echo "# $$file" >> $(CODE_AND_TESTS_OUTPUT); \
		echo "" >> $(CODE_AND_TESTS_OUTPUT); \
		echo '```elixir' >> $(CODE_AND_TESTS_OUTPUT); \
		cat $$file >> $(CODE_AND_TESTS_OUTPUT); \
		echo "" >> $(CODE_AND_TESTS_OUTPUT); \
		echo '```' >> $(CODE_AND_TESTS_OUTPUT); \
		echo "" >> $(CODE_AND_TESTS_OUTPUT); \
		echo "---" >> $(CODE_AND_TESTS_OUTPUT); \
		echo "" >> $(CODE_AND_TESTS_OUTPUT); \
	done
	@echo "Done."

web:
	@echo "Generating $(WEB_OUTPUT)..."
	@rm -f "$(WEB_OUTPUT)"
	@find -H web -type d -name '.git' -prune -o -type f -print | LC_ALL=C sort | while IFS= read -r file; do \
		printf '# %s\n\n' "$$file"; \
		printf '%s\n' '```'; \
		cat "$$file"; \
		printf '\n%s\n\n---\n\n' '```'; \
	done > "$(WEB_OUTPUT)"
	@echo "Done."

docs:
	@echo "Generating $(DOCS_OUTPUT)..."
	@rm -f $(DOCS_OUTPUT)
	@echo "# $(README)" >> $(DOCS_OUTPUT)
	@echo "" >> $(DOCS_OUTPUT)
	@cat $(README) >> $(DOCS_OUTPUT)
	@echo "# $(SECURITY)" >> $(DOCS_OUTPUT)
	@echo "" >> $(DOCS_OUTPUT)
	@cat $(SECURITY) >> $(DOCS_OUTPUT)
	@echo "\n\n---\n" >> $(DOCS_OUTPUT)
	@for file in $$(ls $(DOCS_DIR)/*.md | sort); do \
		filename=$$(basename $$file); \
		echo "# $$filename" >> $(DOCS_OUTPUT); \
		echo "" >> $(DOCS_OUTPUT); \
		cat $$file >> $(DOCS_OUTPUT); \
		echo "\n\n---\n" >> $(DOCS_OUTPUT); \
	done
	@echo "Done."

clean:
	rm -f $(DOCS_OUTPUT) $(CODE_AND_TESTS_OUTPUT) $(CODE_OUTPUT) $(TESTS_OUTPUT) $(WEB_OUTPUT)

