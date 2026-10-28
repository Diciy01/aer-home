package power

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
)

// ParseMAC accepts a 48-bit unicast MAC (aa:bb:cc:dd:ee:ff, aa-bb-…,
// aabb.ccdd.eeff or 12 hex digits) and returns it as lower-case aa:bb:….
func ParseMAC(s string) (string, error) {
	s = strings.TrimSpace(s)
	if len(s) == 12 {
		s = s[0:2] + ":" + s[2:4] + ":" + s[4:6] + ":" + s[6:8] + ":" + s[8:10] + ":" + s[10:12]
	}
	hw, err := net.ParseMAC(s)
	if err != nil || len(hw) != 6 {
		return "", errors.New("MAC-адрес: 6 байт, например 00:11:22:33:44:55")
	}
	if hw[0]&1 == 1 {
		return "", errors.New("MAC-адрес групповой (multicast/broadcast), нужен адрес сетевой карты")
	}
	zero := true
	for _, b := range hw {
		zero = zero && b == 0
	}
	if zero {
		return "", errors.New("MAC-адрес из одних нулей")
	}
	return hw.String(), nil
}

// MagicPacket is 6×0xFF followed by the MAC repeated 16 times (102 bytes).
func MagicPacket(mac string) ([]byte, error) {
	hw, err := net.ParseMAC(mac)
	if err != nil || len(hw) != 6 {
		return nil, errors.New("invalid MAC")
	}
	p := make([]byte, 0, 102)
	for range 6 {
		p = append(p, 0xFF)
	}
	for range 16 {
		p = append(p, hw...)
	}
	return p, nil
}

// CheckDestination accepts IPv4 LAN destinations only: private ranges,
// link-local, loopback (test receivers) and the limited broadcast. A WoL
// packet must never be sent towards the internet.
func CheckDestination(addr string) (net.IP, error) {
	ip := net.ParseIP(strings.TrimSpace(addr)).To4()
	if ip == nil {
		return nil, errors.New("Адрес: IPv4, например широковещательный адрес сети 192.168.1.255")
	}
	if ip.Equal(net.IPv4bcast) || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return ip, nil
	}
	return nil, errors.New("Адрес вне домашней сети: разрешены частные диапазоны, 255.255.255.255 и 127.0.0.0/8")
}

// Interface is a local network interface usable for WoL.
type Interface struct {
	Name      string   `json:"name"`
	MAC       string   `json:"mac"`
	Addresses []string `json:"addresses"`
	// Broadcasts are the IPv4 subnet broadcast addresses of the interface.
	Broadcasts []string `json:"broadcasts"`
	Up         bool     `json:"up"`
	Loopback   bool     `json:"loopback"`
}

// Net abstracts the host network for tests.
type Net interface {
	Interfaces() ([]Interface, error)
	// Send delivers payload as UDP to dst:port, from the interface's IPv4
	// address when iface is set.
	Send(ctx context.Context, iface string, dst net.IP, port int, payload []byte) error
}

// SystemNet is the real network.
type SystemNet struct{}

// Interfaces lists the host's network interfaces with IPv4 addresses.
func (SystemNet) Interfaces() ([]Interface, error) {
	ifs, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	out := []Interface{}
	for _, it := range ifs {
		v := Interface{Name: it.Name, MAC: it.HardwareAddr.String(), Up: it.Flags&net.FlagUp != 0,
			Loopback: it.Flags&net.FlagLoopback != 0, Addresses: []string{}, Broadcasts: []string{}}
		addrs, _ := it.Addrs()
		for _, a := range addrs {
			n, ok := a.(*net.IPNet)
			if !ok || n.IP.To4() == nil {
				continue
			}
			v.Addresses = append(v.Addresses, n.String())
			if it.Flags&net.FlagBroadcast != 0 {
				b := make(net.IP, 4)
				for i := range 4 {
					b[i] = n.IP.To4()[i] | ^n.Mask[len(n.Mask)-4+i]
				}
				v.Broadcasts = append(v.Broadcasts, b.String())
			}
		}
		out = append(out, v)
	}
	return out, nil
}

// Send writes one UDP datagram (Go enables SO_BROADCAST on IPv4 UDP sockets).
func (s SystemNet) Send(ctx context.Context, iface string, dst net.IP, port int, payload []byte) error {
	var laddr *net.UDPAddr
	if iface != "" {
		ifs, err := s.Interfaces()
		if err != nil {
			return err
		}
		for _, it := range ifs {
			if it.Name != iface {
				continue
			}
			if !it.Up {
				return fmt.Errorf("интерфейс %s выключен", iface)
			}
			for _, a := range it.Addresses {
				if ip, _, err := net.ParseCIDR(a); err == nil {
					laddr = &net.UDPAddr{IP: ip}
					break
				}
			}
			if laddr == nil {
				return fmt.Errorf("у интерфейса %s нет IPv4-адреса", iface)
			}
		}
		if laddr == nil {
			return fmt.Errorf("интерфейс %s не найден", iface)
		}
	}
	d := net.Dialer{LocalAddr: laddr, Timeout: 2 * time.Second}
	conn, err := d.DialContext(ctx, "udp4", net.JoinHostPort(dst.String(), fmt.Sprint(port)))
	if err != nil {
		return err
	}
	defer conn.Close()
	_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
	n, err := conn.Write(payload)
	if err == nil && n != len(payload) {
		err = errors.New("пакет отправлен не полностью")
	}
	return err
}

// localMACs are the MACs of this Core host's interfaces (same-machine check).
func localMACs(n Net) map[string]bool {
	out := map[string]bool{}
	ifs, err := n.Interfaces()
	if err != nil {
		return out
	}
	for _, it := range ifs {
		if it.MAC != "" && !it.Loopback {
			out[strings.ToLower(it.MAC)] = true
		}
	}
	return out
}
