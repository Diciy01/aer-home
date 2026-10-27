package remotehost

import (
	"bufio"
	"fmt"
	"os"
	"runtime"
	"strings"
)

// established counts ESTABLISHED TCP connections to a local port, from
// /proc/net/tcp{,6} (Linux). -1 means "cannot tell on this OS".
func established(port int) int {
	if runtime.GOOS != "linux" {
		return -1
	}
	want := fmt.Sprintf(":%04X", port)
	n := 0
	for _, f := range []string{"/proc/net/tcp", "/proc/net/tcp6"} {
		fh, err := os.Open(f)
		if err != nil {
			continue
		}
		sc := bufio.NewScanner(fh)
		for sc.Scan() {
			fs := strings.Fields(sc.Text())
			if len(fs) > 3 && strings.HasSuffix(fs[1], want) && fs[3] == "01" { // 01 = ESTABLISHED
				n++
			}
		}
		fh.Close()
	}
	return n
}
