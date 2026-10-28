package remotehost

import (
	"encoding/binary"
	"unsafe"

	"golang.org/x/sys/windows"
)

var (
	iphlpapi         = windows.NewLazySystemDLL("iphlpapi.dll")
	procGetTcpTable  = iphlpapi.NewProc("GetTcpTable")
	procGetTcp6Table = iphlpapi.NewProc("GetTcp6Table")
)

const mibTCPStateEstab = 5 // MIB_TCP_STATE_ESTAB

// establishedWindows reads the IPv4 and IPv6 TCP tables (GetTcpTable,
// GetTcp6Table): rows are MIB_TCPROW {state, localAddr, localPort, ...}
// and MIB_TCP6ROW {state, localAddr[16], scope, localPort, ...}; ports
// are in network byte order in the low 16 bits.
func establishedWindows(port int) int {
	n4, ok4 := countRows(procGetTcpTable, 20, 0, 8, port)
	n6, ok6 := countRows(procGetTcp6Table, 52, 0, 24, port)
	if !ok4 && !ok6 {
		return -1
	}
	return n4 + n6
}

func countRows(proc *windows.LazyProc, rowSize, stateOff, portOff, port int) (int, bool) {
	if proc.Find() != nil {
		return 0, false
	}
	size := uint32(16 << 10)
	for range 4 { // the table may grow between the size query and the read
		buf := make([]byte, size)
		r, _, _ := proc.Call(uintptr(unsafe.Pointer(&buf[0])), uintptr(unsafe.Pointer(&size)), 0)
		switch windows.Errno(r) {
		case windows.ERROR_INSUFFICIENT_BUFFER:
			size += 4 << 10
			continue
		case windows.ERROR_SUCCESS:
		default:
			return 0, false
		}
		count := int(binary.LittleEndian.Uint32(buf))
		n := 0
		for i := range count {
			row := buf[4+i*rowSize:]
			if len(row) < rowSize {
				break
			}
			state := binary.LittleEndian.Uint32(row[stateOff:])
			local := int(binary.BigEndian.Uint16(row[portOff:]))
			if state == mibTCPStateEstab && local == port {
				n++
			}
		}
		return n, true
	}
	return 0, false
}
