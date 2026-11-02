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
	shellcheck terraformsh

readme:
	cat README.md.tmpl > README.md
	./terraformsh -h| sed -e "s|^#|###|g" >> README.md ; true
