# abra — common entry points. `make run` is the daily driver; targets stay
# stable while the implementation behind them changes.

.PHONY: help run print engine mac app stats kill

# Auto-detect a Developer ID cert; fall back to ad-hoc signing.
SIGN_ID ?= $(shell security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/{print $$2; exit}')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID = -
endif

help:
	@grep -E '^[a-z]+:.*#' Makefile | awk -F':.*# ' '{printf "  make %-8s %s\n", $$1, $$2}'

run: # start dictation (hold right Option, speak, release)
	uv run abra

print: # dictation without pasting — transcripts print to terminal only
	uv run abra --no-paste

engine: # engine alone on the stdio JSON protocol (for shell development)
	uv run abra-engine

mac: # build + run the native Swift shell from the terminal (dev loop)
	cd shells/mac && swift run

app: # bundle Abra.app, sign with Developer ID, install to /Applications
	cd shells/mac && swift build -c release
	rm -rf /Applications/Abra.app
	mkdir -p /Applications/Abra.app/Contents/MacOS
	cp shells/mac/.build/release/AbraShell /Applications/Abra.app/Contents/MacOS/AbraShell
	cp shells/mac/Sources/AbraShell/Info.plist /Applications/Abra.app/Contents/Info.plist
	mkdir -p /Applications/Abra.app/Contents/Resources
	cp shells/mac/icon/AppIcon.icns /Applications/Abra.app/Contents/Resources/AppIcon.icns
	codesign --force --options runtime \
		--entitlements shells/mac/Entitlements.plist \
		--sign "$(SIGN_ID)" /Applications/Abra.app
	@codesign --verify --deep /Applications/Abra.app && echo "signed ✔  →  open /Applications/Abra.app"

stats: # corpus numbers: per-model latency and the idle→latency curve
	@sqlite3 -header -column clips/clips.db \
		"SELECT model, COUNT(*) clips, ROUND(AVG(stt_ms)) avg_ms, MAX(stt_ms) max_ms FROM clips GROUP BY model;"
	@echo
	@sqlite3 -header -column clips/clips.db \
		"SELECT CASE WHEN idle_s IS NULL THEN 'first/unknown' WHEN idle_s<30 THEN '<30s idle' WHEN idle_s<300 THEN '30s-5m idle' ELSE '>5m idle' END bucket, COUNT(*) n, ROUND(AVG(stt_ms)) avg_ms FROM clips GROUP BY bucket ORDER BY avg_ms;"
	@echo
	@sqlite3 clips/clips.db \
		"SELECT 'sessions: ' || COUNT(*) || ', uncorrected clips: ' || (SELECT COUNT(*) FROM clips WHERE corrected IS NULL) FROM sessions;"

kill: # stop a running abra instance
	@pkill -f '\.venv/bin/abra' && echo "killed" || echo "no abra running"

release: # full release: build, sign, notarize, staple, zip, gh release, tap bump
	./scripts/release.sh
