SUZU_DIR := suzu
SUZU_BIN := $(SUZU_DIR)/bin/suzu
SUZU_INSTALL_DIR := $(HOME)/.local/bin

.PHONY: build-cli cli test-cli verify-cli clean

build-cli:
	cd $(SUZU_DIR) && go build -o bin/suzu .

# suzu (nested tmux の額縁 + 通知サイドバー) をビルドして ~/.local/bin へ配置する
cli: build-cli
	mkdir -p $(SUZU_INSTALL_DIR)
	install -m 0755 $(SUZU_BIN) $(SUZU_INSTALL_DIR)/suzu

test-cli:
	cd $(SUZU_DIR) && go vet ./... && go test ./...

# 隔離 socket だけを使う E2E。普段の tmux には触れない
verify-cli: build-cli
	bash $(SUZU_DIR)/verify.sh

clean:
	rm -rf $(SUZU_DIR)/bin

# 引数なしの make で cli を実行する (人が手で動作確認するための入口。検査・テストは CI が行う)
.DEFAULT_GOAL := cli

.PHONY: verify
verify: test-cli verify-cli
	unformatted="$$(gofmt -l $(SUZU_DIR))" || { echo "gofmt の実行に失敗しました"; exit 1; }; test -z "$$unformatted" || { echo "$$unformatted"; echo "gofmt で整形されていないファイルがあります"; exit 1; }
