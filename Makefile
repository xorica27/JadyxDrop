.PHONY: build package icon run clean
build:   ; ./scripts/build.sh
package: ; ./scripts/package.sh
icon:    ; swift scripts/make-icon.swift
run: build ; open build/JadyxDrop.app
clean:   ; rm -rf build dist
