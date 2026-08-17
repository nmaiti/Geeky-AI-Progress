.PHONY: build-linux build-windows build clean

BINARY_NAME := monitor-server
BUILD_DIR := dist
GO_VERSION := 1.25-alpine

build: build-linux build-windows

build-linux:
	mkdir -p $(BUILD_DIR)
	docker run --rm \
		-v $(PWD)/Monitor_sever:/src \
		-w /src \
		golang:$(GO_VERSION) \
		sh -c "go build -o $(BUILD_DIR)/$(BINARY_NAME)-linux-amd64 ."

build-windows:
	mkdir -p $(BUILD_DIR)
	docker run --rm \
		-v $(PWD)/Monitor_sever:/src \
		-w /src \
		-e GOOS=windows \
		-e GOARCH=amd64 \
		golang:$(GO_VERSION) \
		sh -c "go build -o $(BUILD_DIR)/$(BINARY_NAME)-windows-amd64.exe ."

clean:
	rm -rf $(BUILD_DIR)
