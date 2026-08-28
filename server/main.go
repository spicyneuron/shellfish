// Command shellfish-server exposes one Shellfish session over HTTP. Without a
// session path, it asks Shellfish to create one in the current directory.
//
// Build it with: go build -o shellfish-server ./server
package main

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// A first shutdown signal lets an ordinary active turn finish before escalating
// to the same cancellation path as a second signal.
var shutdownDrainPeriod = 10 * time.Second

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)
	log.SetPrefix("shellfish-server: ")
	options, err := parseServerArgs(os.Args[1:])
	if err != nil {
		log.Fatal(err)
	}
	if options.session == "" {
		binary, err := exec.LookPath(options.binary)
		if err != nil {
			log.Fatal(err)
		}
		options.session, err = createSession(binary, options.shellfishArgs)
		if err != nil {
			log.Fatal(err)
		}
	} else if len(options.shellfishArgs) > 0 {
		log.Fatal("Shellfish options require creating a new session")
	}
	if err := serve(options.session, options.bind, options.binary); err != nil {
		log.Fatal(err)
	}
}

type serverOptions struct {
	session       string
	bind          string
	binary        string
	shellfishArgs []string
}

func parseServerArgs(args []string) (serverOptions, error) {
	options := serverOptions{bind: "127.0.0.1:9158", binary: "shellfish"}
	forward := false
	for index := 0; index < len(args); index++ {
		arg := args[index]
		if forward {
			options.shellfishArgs = append(options.shellfishArgs, arg)
			continue
		}
		if arg == "--" {
			options.shellfishArgs = append(options.shellfishArgs, arg)
			forward = true
			continue
		}
		var target *string
		switch arg {
		case "--session", "-session":
			target = &options.session
		case "--bind", "-bind":
			target = &options.bind
		case "--shellfish", "-shellfish":
			target = &options.binary
		default:
			options.shellfishArgs = append(options.shellfishArgs, arg)
			continue
		}
		if index+1 == len(args) || args[index+1] == "" {
			return serverOptions{}, fmt.Errorf("%s requires a value", arg)
		}
		index++
		*target = args[index]
	}
	return options, nil
}

func createSession(binary string, args []string) (string, error) {
	command := exec.Command(binary, append([]string{"exec", "--new"}, args...)...)
	command.Stderr = os.Stderr
	output, err := command.Output()
	if err != nil {
		return "", fmt.Errorf("create session: %w", err)
	}
	session := strings.TrimSuffix(string(output), "\n")
	if session == "" || strings.Contains(session, "\n") {
		return "", errors.New("Shellfish did not return one session path")
	}
	return session, nil
}

func serve(session, bind, binary string) error {
	if session == "" {
		return errors.New("--session is required")
	}
	sessionPath, err := filepath.Abs(session)
	if err != nil {
		return err
	}
	binaryPath, err := exec.LookPath(binary)
	if err != nil {
		return err
	}
	value, err := rand.Int(rand.Reader, big.NewInt(1_000_000))
	if err != nil {
		return fmt.Errorf("generate access code: %w", err)
	}
	accessCode := fmt.Sprintf("%06d", value.Int64())

	// Turns outlive a client disconnect but not the process. Cancelling stops a
	// turn wherever it has got to, so it is reserved for a shutdown that will
	// not drain.
	turns, killTurn := context.WithCancel(context.Background())
	defer killTurn()
	service, err := New(sessionPath, accessCode, NewExec(turns, binaryPath, sessionPath))
	if err != nil {
		return err
	}

	listener, err := net.Listen("tcp", bind)
	if err != nil {
		return err
	}
	if host, _, err := net.SplitHostPort(listener.Addr().String()); err == nil {
		if address := net.ParseIP(host); address != nil && !address.IsLoopback() {
			log.Printf("warning: %s is reachable off this host; use TLS across untrusted networks", host)
		}
	}
	signals := make(chan os.Signal, 2)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)
	tools := make([]string, len(service.header.Harness.Tools))
	for i, tool := range service.header.Harness.Tools {
		tools[i] = tool.Name
	}
	printStartupBanner(os.Stderr, "http://"+listener.Addr().String(), accessCode,
		service.header.Cwd, tools, service.header.Harness.Sandbox)
	log.Printf("serving session %s", sessionPath)
	return serveHTTP(listener, service, killTurn, signals)
}

func printStartupBanner(w io.Writer, url, accessCode, project string, tools []string, sandbox bool) {
	fmt.Fprint(w, `
╭─╮╷ ╷╭─╴╷  ╷  ╭─╴╷╭─╮╷ ╷
╰─╮├─┤├╴ │  │  ├╴ │╰─╮├─┤
╰─╯╵ ╵╰─╴╰─╴╰─╴╵  ╵╰─╯╵ ╵
╭─╮╭─╴╭─╮╷ ╷╭─╴╭─╮
╰─╮├╴ ├┬╯│╭╯├╴ ├┬╯
╰─╯╰─╴╵╰╴╰╯ ╰─╴╵╰╴

╭──🎩───
╰𝆒 ◕ )]]]]]╮
   <<<<<   ⨇

`)
	toolNames := "none"
	if len(tools) > 0 {
		toolNames = strings.Join(tools, ", ")
	}
	sandboxState := "disabled"
	if sandbox {
		sandboxState = "enabled"
	}
	fmt.Fprintf(w, "\x1b[1mProject:\x1b[0m %s\n\x1b[1mTools:  \x1b[0m %s\n"+
		"\x1b[1mSandbox:\x1b[0m %s\n\x1b[1mURL:    \x1b[0m %s\n\x1b[1mCode:   \x1b[0m %s-%s\n\n",
		project, toolNames, sandboxState, url, accessCode[:3], accessCode[3:])
}

func serveHTTP(listener net.Listener, service *Service, killTurn context.CancelFunc,
	signals <-chan os.Signal) error {
	httpServer := &http.Server{
		Handler:           withUI(service),
		ReadHeaderTimeout: 10 * time.Second,
		MaxHeaderBytes:    1 << 16,
	}
	httpRequests, disconnectClients := context.WithCancel(context.Background())
	defer disconnectClients()
	httpServer.BaseContext = func(net.Listener) context.Context { return httpRequests }

	drained := make(chan error, 1)
	go func() {
		<-signals
		log.Print("shutting down; waiting for any active turn to commit")
		turnDone := service.beginDrain()
		disconnectClients()
		shutdown := make(chan error, 1)
		go func() { shutdown <- httpServer.Shutdown(context.Background()) }()
		timer := time.NewTimer(shutdownDrainPeriod)
		defer timer.Stop()
		select {
		case <-signals:
			log.Print("terminating the active turn")
			killTurn()
			<-turnDone
		case <-turnDone:
		case <-timer.C:
			log.Print("active turn did not settle; terminating it")
			killTurn()
			<-turnDone
		}
		drained <- <-shutdown
	}()

	if err := httpServer.Serve(listener); !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return <-drained
}
