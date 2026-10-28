package home.aer.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class EndpointTest {
    private fun ok(s: String) = checkEndpoint(s) as? EndpointCheck.Ok ?: error("expected Ok for $s: ${checkEndpoint(s)}")
    private fun invalid(s: String) = checkEndpoint(s) as? EndpointCheck.Invalid ?: error("expected Invalid for $s")

    @Test
    fun schemeIsAddedAndTrailingPartsKept() {
        assertEquals("http://192.168.1.10:8787/", ok("192.168.1.10:8787").url.toString())
        assertEquals("http://10.0.2.2:18798/", ok(" http://10.0.2.2:18798 ").url.toString())
    }

    @Test
    fun cleartextToPrivateNetworkWarns() {
        assertNotNull(ok("http://192.168.0.5:8787").warning)
        assertNotNull(ok("http://172.20.1.1:8787").warning)
        assertNotNull(ok("http://home-server:8787").warning)
        assertNotNull(ok("http://nas.local:8787").warning)
        assertNotNull(ok("http://[fd00::1]:8787").warning)
    }

    @Test
    fun loopbackTailnetAndHttpsNeedNoWarning() {
        assertNull(ok("http://127.0.0.1:8787").warning)
        assertNull(ok("http://localhost:8787").warning)
        assertNull(ok("http://100.101.102.103:8787").warning)
        assertNull(ok("http://core.tailnet-name.ts.net:8787").warning)
        assertNull(ok("https://core.example.org").warning)
    }

    @Test
    fun cleartextToPublicAddressIsRefused() {
        assertTrue(invalid("http://198.51.100.7:8787").message.contains("публичный"))
        assertTrue(invalid("http://core.example.org:8787").message.contains("публичный"))
        // 100.128.x is outside Tailscale's 100.64/10.
        invalid("http://100.128.0.1:8787")
    }

    @Test
    fun malformedInputIsRefused() {
        invalid("")
        invalid("ftp://192.168.1.1")
        invalid("http://user:pass@192.168.1.1:8787")
        invalid("http://192.168.1.1:8787/?token=x")
        invalid("http://")
    }

    @Test
    fun hostScopes() {
        assertEquals(HostScope.Loopback, hostScope("127.0.0.1"))
        assertEquals(HostScope.Loopback, hostScope("::1"))
        assertEquals(HostScope.Private, hostScope("10.0.2.2"))
        assertEquals(HostScope.Private, hostScope("169.254.1.1"))
        assertEquals(HostScope.Tailnet, hostScope("100.64.0.1"))
        assertEquals(HostScope.LocalName, hostScope("router.home.arpa"))
        assertEquals(HostScope.Public, hostScope("203.0.113.5"))
    }
}
