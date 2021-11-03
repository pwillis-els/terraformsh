all: lint test-main readme

.PHONY: test test-main test-extensions lint readme
test: test-main test-extensions

test-main:
	export PATH="`pwd`:$$PATH" ; \
    ./test.sh tests/*.t

lint:
	shellcheck \
        --exclude=SC2086 \
        --exclude=SC2162 \
        --exclude=SC1091 \
        --exclude=SC2004 \
        --exclude=SC1090 \
        --exclude=SC2166 \
        --exclude=SC2046 \
        terraformsh

readme:
	cat README.md.tmpl > README.md
	./terraformsh -h >> README.md ; true
