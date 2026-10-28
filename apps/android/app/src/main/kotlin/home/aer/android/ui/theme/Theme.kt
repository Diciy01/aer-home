package home.aer.android.ui.theme

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Shapes
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import home.aer.core.Tone

/** Cozy Beige Tech Home tokens (docs/DESIGN_TOKENS.md, apps/desktop/lib/src/theme/tokens.dart). */
object AerColors {
    val background = Color(0xFFF4EFE7)
    val surface = Color(0xFFFFFCF7)
    val surfaceMuted = Color(0xFFEDE5D8)
    val border = Color(0xFFD8CCBE)
    val ink = Color(0xFF40352E)
    val inkMuted = Color(0xFF75675D)
    val accent = Color(0xFFA77E5F)
    val accentSoft = Color(0xFFE8CFB4)
    val sage = Color(0xFF718E76)
    val blue = Color(0xFF789CAA)
    val amber = Color(0xFFBC8A43)
    val terracotta = Color(0xFFBA6D5B)
    val lavender = Color(0xFFA497B5)
}

/** Status colour; always shown together with a text label. */
fun toneColor(t: Tone): Color = when (t) {
    Tone.Ok -> AerColors.sage
    Tone.Warning -> AerColors.amber
    Tone.Critical -> AerColors.terracotta
    Tone.Info -> AerColors.blue
    Tone.Muted -> AerColors.inkMuted
}

private val scheme = lightColorScheme(
    primary = AerColors.accent,
    onPrimary = Color.White,
    primaryContainer = AerColors.accentSoft,
    onPrimaryContainer = AerColors.ink,
    secondary = AerColors.sage,
    onSecondary = Color.White,
    secondaryContainer = Color(0xFFDDE3D0),
    onSecondaryContainer = AerColors.ink,
    tertiary = AerColors.blue,
    background = AerColors.background,
    onBackground = AerColors.ink,
    surface = AerColors.surface,
    onSurface = AerColors.ink,
    surfaceVariant = AerColors.surfaceMuted,
    onSurfaceVariant = AerColors.inkMuted,
    surfaceContainer = AerColors.surfaceMuted,
    surfaceContainerLow = AerColors.surface,
    surfaceContainerHigh = Color(0xFFF1EADF),
    outline = AerColors.border,
    outlineVariant = AerColors.border,
    error = AerColors.terracotta,
    onError = Color.White,
)

@Composable
fun AerTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = scheme,
        shapes = Shapes(
            small = RoundedCornerShape(12.dp),
            medium = RoundedCornerShape(16.dp),
            large = RoundedCornerShape(20.dp),
        ),
        content = content,
    )
}
