DOCS_DIR := docs
README := README.md
OUTPUT := combined.md

.PHONY: all clean

all: $(OUTPUT)

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
	rm -f $(OUTPUT)

