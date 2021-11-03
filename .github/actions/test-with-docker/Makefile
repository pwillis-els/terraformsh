docker-build:
	docker build -t test-with-docker:latest .

docker-run:
	docker run --rm -it -v $$(pwd)/../../..:/app -w /app test-with-docker:latest
