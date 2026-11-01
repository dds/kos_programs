TAG ?=
CHECK_JOBS ?=
CHECK_FLAGS = $(if $(CHECK_JOBS),--jobs $(CHECK_JOBS))

.PHONY: help check check-slow check-all check-times audit pre-commit require-tag stamp-version commit-version tag-version push-version release-version watch-sync

help:
	@echo "Version/log tag workflow:"
	@echo "  make stamp-version TAG=kos-YYYYMMDD-N"
	@echo "  make commit-version TAG=kos-YYYYMMDD-N"
	@echo "  make tag-version TAG=kos-YYYYMMDD-N"
	@echo "  make push-version TAG=kos-YYYYMMDD-N"
	@echo "  make release-version TAG=kos-YYYYMMDD-N"
	@echo "  make pre-commit"
	@echo "  make check / make check-slow / make check-all / make check-times / make audit"
	@echo "  make watch-sync"

pre-commit: check

check:
	python3 -B scripts/run_checks.py $(CHECK_FLAGS)

check-slow:
	python3 -B scripts/run_checks.py --suite slow --timings $(CHECK_FLAGS)

check-all:
	python3 -B scripts/run_checks.py --suite all $(CHECK_FLAGS)

check-times:
	python3 -B scripts/run_checks.py --suite all --timings --jobs $(or $(CHECK_JOBS),1)

audit:
	python3 -B scripts/check_codebase.py --report

require-tag:
	@test -n "$(TAG)" || (echo "Set TAG=kos-YYYYMMDD-N" && exit 1)

stamp-version: require-tag
	@printf "%s\n" "$(TAG)" > VERSION
	@git add VERSION
	@echo "Stamped VERSION=$(TAG)"

commit-version: stamp-version
	@git diff --cached --quiet && (echo "No staged VERSION change."; exit 1) || true
	git commit -m "Stamp code version $(TAG)"

tag-version: require-tag
	@test "$$(cat VERSION 2>/dev/null)" = "$(TAG)" || (echo "VERSION does not match $(TAG)" && exit 1)
	@git diff --quiet || (echo "Working tree has unstaged changes; commit first." && exit 1)
	@git diff --cached --quiet || (echo "Index has staged changes; commit first." && exit 1)
	@! git rev-parse -q --verify "refs/tags/$(TAG)" >/dev/null || (echo "Tag $(TAG) already exists." && exit 1)
	git tag -a "$(TAG)" -m "Code version $(TAG)"

push-version: require-tag
	git push
	git push origin "$(TAG)"

release-version: commit-version tag-version push-version

watch-sync:
	./scripts/watch-sync.sh
