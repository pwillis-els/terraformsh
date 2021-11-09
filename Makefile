all: lint test-main readme

.PHONY: test test-main test-extensions lint readme
test: test-main test-extensions

test-main:
	export PATH="`pwd`:$$PATH" ; \
    ./test.sh tests/*.t

docker-test-main-build:
	make -C .github/actions/test-with-docker docker-build

docker-test-main-run: docker-test-main-build
	make -C .github/actions/test-with-docker docker-run


lint:
	shellcheck \
        --exclude=SC2086 \
        --exclude=SC2162 \
        --exclude=SC1091 \
        --exclude=SC2004 \
        --exclude=SC1090 \
        --exclude=SC2166 \
        --exclude=SC2046 \
        --exclude=SC2120 \
        --exclude=SC2207 \
        --exclude=SC2119 \
        --exclude=SC2181 \
        terraformsh

readme:
	cat README.md.tmpl > README.md
	./terraformsh -h >> README.md ; true
