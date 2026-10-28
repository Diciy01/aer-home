package home.aer.core

import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress

/** Result of checking the Core address a user typed in the settings. */
sealed interface EndpointCheck {
    /** Usable; [warning] is shown next to the field but does not block saving. */
    data class Ok(val url: HttpUrl, val warning: String?) : EndpointCheck

    data class Invalid(val message: String) : EndpointCheck
}

/** Where a host lives, judged only from the address itself (no DNS lookups). */
enum class HostScope { Loopback, Tailnet, Private, LocalName, Public }

/**
 * Validates a Core base URL. Core has no TLS of its own (docs/SECURITY.md:
 * access only from the home LAN or a private overlay such as Tailscale), so
 * plain http is allowed only to private/tailnet/local addresses — otherwise the
 * bearer token would cross the internet in clear text.
 */
fun checkEndpoint(input: String): EndpointCheck {
    val raw = input.trim()
    if (raw.isEmpty()) return EndpointCheck.Invalid("Укажите адрес Core, например http://192.168.1.10:8787")
    val withScheme = if ("://" in raw) raw else "http://$raw"
    val scheme = withScheme.substringBefore("://").lowercase()
    if (scheme != "http" && scheme != "https") return EndpointCheck.Invalid("Поддерживаются только http:// и https://")
    val url = withScheme.toHttpUrlOrNull() ?: return EndpointCheck.Invalid("Не похоже на адрес: $raw")
    if (url.username.isNotEmpty() || url.password.isNotEmpty()) {
        return EndpointCheck.Invalid("Логин и пароль в адресе не поддерживаются: токен вводится отдельно")
    }
    if (url.query != null || url.fragment != null) return EndpointCheck.Invalid("Адрес не должен содержать «?» или «#»")
    val clean = url.newBuilder().query(null).fragment(null).build()
    if (clean.isHttps) return EndpointCheck.Ok(clean, null)
    return when (hostScope(clean.host)) {
        HostScope.Loopback, HostScope.Tailnet -> EndpointCheck.Ok(clean, null)
        HostScope.Private, HostScope.LocalName -> EndpointCheck.Ok(
            clean,
            "Соединение без шифрования: используйте этот адрес только в домашней сети или через Tailscale.",
        )
        HostScope.Public -> EndpointCheck.Invalid(
            "Адрес похож на публичный: по http токен ушёл бы в интернет открытым текстом. " +
                "Используйте адрес домашней сети, Tailscale или https.",
        )
    }
}

fun hostScope(host: String): HostScope {
    val h = host.lowercase().removePrefix("[").removeSuffix("]")
    if (h == "localhost") return HostScope.Loopback
    if (h.endsWith(".ts.net")) return HostScope.Tailnet
    if (looksLikeIp(h)) {
        val addr = try {
            InetAddress.getByName(h) // literal only: no DNS for an IP string
        } catch (_: Exception) {
            return HostScope.Public
        }
        return when {
            addr.isLoopbackAddress -> HostScope.Loopback
            addr is Inet4Address && inCgnat(addr) -> HostScope.Tailnet
            addr.isSiteLocalAddress || addr.isLinkLocalAddress -> HostScope.Private
            addr is Inet6Address && (addr.address[0].toInt() and 0xfe) == 0xfc -> HostScope.Private
            else -> HostScope.Public
        }
    }
    if ('.' !in h || h.endsWith(".local") || h.endsWith(".lan") || h.endsWith(".home.arpa") || h.endsWith(".internal")) {
        return HostScope.LocalName
    }
    return HostScope.Public
}

private fun looksLikeIp(h: String) = ':' in h || h.all { it.isDigit() || it == '.' }

/** 100.64.0.0/10 — Tailscale addresses (carrier-grade NAT range). */
private fun inCgnat(a: Inet4Address): Boolean {
    val b = a.address
    return (b[0].toInt() and 0xff) == 100 && (b[1].toInt() and 0xc0) == 64
}
