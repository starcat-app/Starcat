// 测试进程只注入内存里的设备凭据和回环地址。命令解析、工具发现、HTTP 和 stdio 都由正式 CLI 执行。
package main

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/starcat-app/starcat-cli/internal/cli"
	"github.com/starcat-app/starcat-cli/internal/config"
	"github.com/starcat-app/starcat-cli/internal/credential"
	keyring "github.com/zalando/go-keyring"
)

// fixtureProfile 仅被读取，若业务意外尝试修改配对，测试立即失败。
type fixtureProfile struct{ config.Profile }

func (f fixtureProfile) Load() (config.Profile, error) { return f.Profile, f.Validate() }
func (fixtureProfile) Save(config.Profile) error       { return fmt.Errorf("unexpected pairing write") }
func (fixtureProfile) Delete() error                   { return fmt.Errorf("unexpected unpair") }

func main() {
	keyring.MockInit()
	store := credential.KeyringStore{}
	if err := store.Set("tag-graph-test", os.Getenv("FIXTURE_TOKEN")); err != nil {
		panic(err)
	}
	runner := cli.Runner{Profiles: fixtureProfile{config.Profile{Endpoint: os.Getenv("FIXTURE_ENDPOINT"), DeviceID: "tag-graph-test", ProtocolVersion: config.CurrentProtocolVersion}}, Credentials: store, Stdin: os.Stdin, Stdout: os.Stdout, Stderr: os.Stderr}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := runner.Run(ctx, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
