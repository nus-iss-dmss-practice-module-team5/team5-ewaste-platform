package securitytest

import (
	"os/exec"
)

// INTENTIONALLY VULNERABLE - FOR CI TEST ONLY
func RunUserCommand(userInput string) error {
	cmd := exec.Command("sh", "-c", userInput)
	return cmd.Run()
}