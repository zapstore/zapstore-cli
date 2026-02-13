BINARY   := zapstore
MODULE   := github.com/zapstore/zapstore
BUILD    := build

# Populated at build time via ldflags (add a Version var in main to use).
VERSION  ?= $(shell git describe --tags --always --dirty 2>/dev/null || echo dev)
COMMIT   := $(shell git rev-parse --short HEAD 2>/dev/null)
DATE     := $(shell date -u +%Y-%m-%dT%H:%M:%SZ)
LDFLAGS  := -s -w

PLATFORMS := darwin-arm64 linux-amd64 linux-arm64

.PHONY: all clean $(PLATFORMS)

all: $(PLATFORMS)

darwin-arm64:
	GOOS=darwin GOARCH=arm64 go build -ldflags '$(LDFLAGS)' -o $(BUILD)/$(BINARY)-darwin-arm64 .

linux-amd64:
	GOOS=linux GOARCH=amd64 go build -ldflags '$(LDFLAGS)' -o $(BUILD)/$(BINARY)-linux-amd64 .

linux-arm64:
	GOOS=linux GOARCH=arm64 go build -ldflags '$(LDFLAGS)' -o $(BUILD)/$(BINARY)-linux-arm64 .

clean:
	rm -rf $(BUILD)
