package home.aer.scene

// Materials, lighting and room kinds: the same ids and colours as the desktop
// catalog (apps/desktop/lib/src/scene/catalog/scene_catalog_data.dart).
// Colours are ARGB longs so this module stays free of Android types.

object SceneCatalog {
    val floors: Map<String, Long> = mapOf(
        "oak" to 0xFFD9B58C,
        "oak_warm" to 0xFFCFA47D,
        "tile_warm" to 0xFFE2C9AE,
        "tile" to 0xFFE9DFD1,
        "stone_light" to 0xFFDCD3C6,
        "carpet" to 0xFFDCCBB4,
        "concrete" to 0xFFD5CEC6,
    )

    val walls: Map<String, Long> = mapOf(
        "milk" to 0xFFF8F0E4,
        "cream" to 0xFFF2E5D0,
        "beige" to 0xFFEBDAC2,
        "sand" to 0xFFE6D2B5,
        "sage_light" to 0xFFDDE3D0,
        "taupe_warm" to 0xFFD3C3B2,
    )

    /** Lighting preset tint (alpha = strength); absent = daylight. */
    val lights: Map<String, Long> = mapOf(
        "warm" to 0x26F2A65A,
        "dim" to 0x2E3A2C24,
        "cool" to 0x1A8FB4CC,
    )

    /** Object finish tint (metadata `finish`). */
    val finishes: Map<String, Long> = mapOf(
        "light" to 0x40FFF8EE,
        "dark" to 0x386B4A36,
        "sage" to 0x3A8DA78C,
        "blue" to 0x388FA8B6,
    )

    val roomKinds: Map<String, String> = mapOf(
        "office" to "Кабинет",
        "living" to "Гостиная",
        "server" to "Серверная",
        "network" to "Сетевая",
        "automation" to "Автоматизация",
        "bedroom" to "Спальня",
        "kitchen" to "Кухня",
        "custom" to "Другое",
    )

    /** Neutral fallbacks for materials unknown to this client (SCENE_FORMAT.md). */
    const val FALLBACK_FLOOR = 0xFFDCD3C6
    const val FALLBACK_WALL = 0xFFEDE5D8

    fun floorColor(id: String) = floors[id] ?: FALLBACK_FLOOR
    fun wallColor(id: String) = walls[id] ?: FALLBACK_WALL

    /**
     * Body colour of an asset for the simplified mobile art (box + details).
     * Devices are darker and cooler, furniture warm wood, textiles soft.
     */
    fun assetColor(assetId: String): Long = when (assetId.substringAfter('/')) {
        "desk", "side_table", "coffee_table", "tv_stand", "bookshelf", "shelf", "crate" -> 0xFFB98D66
        "sofa" -> 0xFFC9A98A
        "office_chair" -> 0xFF8C7A6D
        "rug" -> 0xFFE3C7A6
        "plant" -> 0xFF7F9B78
        "painting" -> 0xFFD8B48A
        "desk_lamp", "floor_lamp" -> 0xFFE9D3A9
        "monitor", "tv", "terminal" -> 0xFF4E4540
        "pc_tower", "server_box", "server_rack", "network_cabinet" -> 0xFF6F655E
        "router", "network_switch", "tv_stick", "link_panel" -> 0xFF8A8079
        "bot", "bot_station" -> 0xFF9BB0B8
        else -> 0xFFC2AE98
    }

    /** Assets that get a "screen" face (lit when the bound device is online). */
    fun hasScreen(assetId: String) = assetId.substringAfter('/') in setOf("monitor", "tv", "terminal")
}
