.PHONY: test integration lint

test:
	nvim --headless -u NONE -i NONE -l tests/run.lua
	nvim --headless -u NONE -i NONE -l tests/renderer.lua
	nvim --headless -u NONE -i NONE -l tests/preview_image.lua

integration:
	nvim --headless -u NONE -i NONE -l tests/integration.lua

lint:
	stylua --check lua tests
