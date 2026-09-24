DOCS_DIR := docs
README := README.md
OUTPUT := combined.md
CODE_OUTPUT := combined_code.txt
TESTS_OUTPUT := combined_tests.txt

.PHONY: all clean code tests client

all: $(OUTPUT)

client:

	@echo "Building Current CLI..."
	@mix escript.build
	@echo "Built ./current"

code: $(CODE_OUTPUT)

tests: $(TESTS_OUTPUT)

$(TESTS_OUTPUT):
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

$(CODE_OUTPUT):
	@echo "Generating $(CODE_OUTPUT)..."
	@rm -f $(CODE_OUTPUT)
	@for file in $$(find lib test -type f -name '*.ex' -o -name '*.exs' | sort); do \
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

$(OUTPUT):
	@echo "Generating $(OUTPUT)..."
	@rm -f $(OUTPUT)
	@echo "# $(README)" >> $(OUTPUT)
	@echo "" >> $(OUTPUT)
	@cat $(README) >> $(OUTPUT)
	@echo "\n\n---\n" >> $(OUTPUT)
	@for file in $$(ls $(DOCS_DIR)/*.md | sort); do \
		filename=$$(basename $$file); \
		echo "# $$filename" >> $(OUTPUT); \
		echo "" >> $(OUTPUT); \
		cat $$file >> $(OUTPUT); \
		echo "\n\n---\n" >> $(OUTPUT); \
	done
	@echo "Done."

clean:
	rm -f $(OUTPUT) $(CODE_OUTPUT) $(TESTS_OUTPUT)

