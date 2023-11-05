docker-build:
	docker build -t test-with-docker:latest --build-arg TFVER=1.6.3 .

docker-run:
	docker run --rm -it -v $$(pwd)/../../..:/app -w /app test-with-docker:latest terraform --version
