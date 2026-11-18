.PHONY: all book-en labs-en clean

all: book-en labs-en

book-en:
	quarto render en --to pdf --output book-en.pdf

labs-en:
	@for f in en/labs/*.qmd; do \
		echo "Rendering $$f";\
		quarto render $$f --to pdf; \
	done

clean:
	rm -rf _output .quarto