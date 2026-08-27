.PHONY: build run test clean

build:
	./scripts/build.zsh

run:
	./scripts/run.zsh

test:
	./scripts/test.zsh

clean:
	@echo "Remove .build manually if a clean rebuild is required."
