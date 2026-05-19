.PHONY: bootstrap xcodeproj build run clean python-test python-format

# Regenerate MLXLab.xcodeproj from project.yml. Requires xcodegen (brew install xcodegen).
xcodeproj:
	xcodegen generate

bootstrap: xcodeproj
	@echo
	@echo "Now open MLXLab.xcodeproj in Xcode and ⌘R to run."
	@echo "First launch will create a Python venv under ~/Library/Application Support/MLXLab/venv"
	@echo "and pip install mlx-lm + deps. This takes a few minutes on first run."

build:
	xcodebuild -project MLXLab.xcodeproj -scheme MLXLab -configuration Debug build

run: build
	open ./build/Debug/MLXLab.app

# Smoke-test the Python backend without the GUI.
python-test:
	cd MLXLab/python_backend && \
		printf '{"op":"ping","id":"1"}\n{"op":"shutdown","id":"2"}\n' | python3 server.py

clean:
	rm -rf MLXLab.xcodeproj build
