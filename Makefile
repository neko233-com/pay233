.PHONY: test test-server test-lib test-race test-server-race test-lib-race vet vet-server vet-lib smoke

test: test-server test-lib

test-server:
	cd pay233-server && go test -cover ./...

test-lib:
	cd pay233-lib-go && go test -cover ./...

test-race: test-server-race test-lib-race

test-server-race:
	cd pay233-server && go test -race -cover ./...

test-lib-race:
	cd pay233-lib-go && go test -race -cover ./...

vet: vet-server vet-lib

vet-server:
	cd pay233-server && go vet ./...

vet-lib:
	cd pay233-lib-go && go vet ./...

smoke:
	powershell -NoProfile -ExecutionPolicy Bypass -File scripts/smoke.ps1
