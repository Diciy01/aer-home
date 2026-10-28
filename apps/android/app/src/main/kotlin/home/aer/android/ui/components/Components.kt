package home.aer.android.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Devices
import androidx.compose.material.icons.filled.Dns
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.Memory
import androidx.compose.material.icons.filled.PhoneAndroid
import androidx.compose.material.icons.filled.Router
import androidx.compose.material.icons.filled.SmartToy
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Tv
import androidx.compose.material.icons.filled.Widgets
import androidx.compose.material.icons.outlined.CloudOff
import androidx.compose.material.icons.outlined.ErrorOutline
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import home.aer.android.ui.theme.AerColors
import home.aer.android.ui.theme.toneColor
import home.aer.core.HomeSnapshot
import home.aer.core.Link
import home.aer.core.StatusText
import home.aer.core.ago
import java.time.Instant

/** Coloured dot + text: status is never colour only. */
@Composable
fun StatusBadge(status: StatusText, modifier: Modifier = Modifier, stale: Boolean = false) {
    val c = toneColor(status.tone)
    Row(
        modifier
            .clip(RoundedCornerShape(50))
            .background(c.copy(alpha = if (stale) 0.08f else 0.14f))
            .padding(horizontal = 10.dp, vertical = 4.dp)
            .semantics { contentDescription = "Состояние: ${status.label}${if (stale) ", устарело" else ""}" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).clip(CircleShape).background(if (stale) c.copy(alpha = 0.45f) else c))
        Spacer(Modifier.width(6.dp))
        Text(
            status.label + if (stale) " · устарело" else "",
            style = MaterialTheme.typography.labelMedium,
            color = AerColors.ink,
            maxLines = 1,
        )
    }
}

@Composable
fun SectionCard(
    title: String,
    modifier: Modifier = Modifier,
    trailing: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = MaterialTheme.shapes.large,
        color = AerColors.surface,
        border = androidx.compose.foundation.BorderStroke(1.dp, AerColors.border),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.weight(1f))
                trailing?.invoke()
            }
            content()
        }
    }
}

/** A tappable row: icon, title, subtitle, trailing badge. */
@Composable
fun ItemRow(
    title: String,
    subtitle: String?,
    icon: ImageVector?,
    modifier: Modifier = Modifier,
    badge: (@Composable () -> Unit)? = null,
    onClick: (() -> Unit)? = null,
) {
    Row(
        modifier
            .fillMaxWidth()
            .clip(MaterialTheme.shapes.medium)
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(vertical = 10.dp, horizontal = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Box(
                Modifier.size(40.dp).clip(RoundedCornerShape(12.dp)).background(AerColors.surfaceMuted),
                contentAlignment = Alignment.Center,
            ) { Icon(icon, null, tint = AerColors.accent) }
            Spacer(Modifier.width(12.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge, maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (!subtitle.isNullOrEmpty()) {
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = AerColors.inkMuted, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
        }
        if (badge != null) {
            Spacer(Modifier.width(8.dp))
            badge()
        }
        if (onClick != null) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = AerColors.inkMuted)
    }
}

@Composable
fun KeyValue(key: String, value: String) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
        Text(key, style = MaterialTheme.typography.bodyMedium, color = AerColors.inkMuted, modifier = Modifier.weight(0.42f))
        Text(value, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(0.58f))
    }
}

@Composable
fun EmptyNote(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.bodyMedium, color = AerColors.inkMuted, modifier = modifier.padding(vertical = 4.dp))
}

@Composable
fun ErrorNote(text: String, modifier: Modifier = Modifier, onRetry: (() -> Unit)? = null) {
    Row(
        modifier
            .fillMaxWidth()
            .clip(MaterialTheme.shapes.medium)
            .background(AerColors.terracotta.copy(alpha = 0.10f))
            .padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(Icons.Outlined.ErrorOutline, null, tint = AerColors.terracotta)
        Spacer(Modifier.width(8.dp))
        Text(text, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        if (onRetry != null) TextButton(onClick = onRetry) { Text("Повторить") }
    }
}

/**
 * Shown above every screen whenever the data on it is not fresh: Core
 * unreachable, token rejected, foreign service, or simply outdated.
 */
@Composable
fun ConnectionBanner(snapshot: HomeSnapshot, now: Instant, stale: Boolean, onOpenSettings: () -> Unit, modifier: Modifier = Modifier) {
    val (icon, text, action) = when (snapshot.link) {
        Link.NotConfigured -> Triple(Icons.Outlined.Key, "Core не настроен: укажите адрес и токен", true)
        Link.Unauthorized -> Triple(Icons.Outlined.Key, "${snapshot.linkMessage}. Проверьте токен в настройках", true)
        Link.Unreachable -> Triple(
            Icons.Outlined.CloudOff,
            snapshot.linkMessage + if (snapshot.hasData) ". Показаны данные, полученные ${ago(snapshot.lastSuccessAt, now)}" else "",
            true,
        )
        Link.Incompatible -> Triple(Icons.Outlined.ErrorOutline, snapshot.linkMessage, true)
        Link.Connecting -> Triple(Icons.Outlined.History, "Подключаемся к Core…", false)
        Link.Online -> if (stale) {
            Triple(Icons.Outlined.History, "Данные устарели: последнее обновление ${ago(snapshot.lastSuccessAt, now)}", false)
        } else {
            return
        }
    }
    val tone = if (snapshot.link == Link.Connecting || (snapshot.link == Link.Online)) AerColors.amber else AerColors.terracotta
    Row(
        modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 6.dp)
            .clip(MaterialTheme.shapes.medium)
            .background(tone.copy(alpha = 0.12f))
            .border(1.dp, tone.copy(alpha = 0.35f), MaterialTheme.shapes.medium)
            .padding(horizontal = 12.dp, vertical = 8.dp)
            .semantics { contentDescription = "Связь с Core: $text" },
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = tone)
        Spacer(Modifier.width(8.dp))
        Text(text, style = MaterialTheme.typography.bodySmall, modifier = Modifier.weight(1f))
        if (action) TextButton(onClick = onOpenSettings) { Text("Настройки") }
    }
}

/** Icon for a Registry entity type (registry/types icons). */
fun typeIcon(type: String): ImageVector = when (type) {
    "computer" -> Icons.Filled.Computer
    "server" -> Icons.Filled.Dns
    "router" -> Icons.Filled.Router
    "network_device" -> Icons.Filled.Hub
    "television" -> Icons.Filled.Tv
    "mobile_device" -> Icons.Filled.PhoneAndroid
    "telegram_bot", "automation" -> Icons.Filled.SmartToy
    "docker_container", "application" -> Icons.Filled.Widgets
    "storage", "database" -> Icons.Filled.Storage
    "service", "process" -> Icons.Filled.Memory
    else -> Icons.Filled.Devices
}
