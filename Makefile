# Use the same Debug app packaging as CI for local development.
.PHONY: build run

build:
	./scripts/build-app.sh debug

run: build
	open "$(CURDIR)/.build/Lane.app"
