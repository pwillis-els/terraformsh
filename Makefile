all: lint readme

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
	rm -f README.md ; ./terraformsh -h > README.md ; true
