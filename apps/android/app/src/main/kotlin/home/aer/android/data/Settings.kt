package home.aer.android.data

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** The two interface modes; null until the user picks one on first launch. */
enum class UiMode(val wire: String) {
    House("house"),
    Classic("classic"),
    ;

    companion object {
        fun fromWire(s: String?) = entries.firstOrNull { it.wire == s }
    }
}

/** Non-secret settings plus the encrypted token, in the app's private storage (no backup). */
class SettingsStore(context: Context, private val vault: TokenVault = KeystoreTokenVault()) {
    private val prefs: SharedPreferences = context.getSharedPreferences("aer_settings", Context.MODE_PRIVATE)

    var coreUrl: String?
        get() = prefs.getString(KEY_URL, null)
        set(v) = prefs.edit().putString(KEY_URL, v).apply()

    var mode: UiMode?
        get() = UiMode.fromWire(prefs.getString(KEY_MODE, null))
        set(v) = prefs.edit().putString(KEY_MODE, v?.wire).apply()

    val hasToken get() = prefs.contains(KEY_TOKEN)

    /** Decrypted token, or null when none is stored or the key is gone (then the user re-enters it). */
    fun token(): String? {
        val sealed = prefs.getString(KEY_TOKEN, null) ?: return null
        return try {
            vault.open(sealed)
        } catch (_: Exception) {
            null
        }
    }

    /** Stores the token encrypted; never falls back to plain text. */
    fun saveToken(token: String) {
        prefs.edit().putString(KEY_TOKEN, vault.seal(token)).apply()
    }

    fun clearToken() = prefs.edit().remove(KEY_TOKEN).apply()

    private companion object {
        const val KEY_URL = "core_url"
        const val KEY_MODE = "ui_mode"
        const val KEY_TOKEN = "core_token_sealed"
    }
}

interface TokenVault {
    fun seal(plain: String): String
    fun open(sealed: String): String
}

/**
 * AES-256-GCM with a non-exportable key in AndroidKeyStore. The ciphertext
 * (IV + data, Base64) is all that lands in SharedPreferences.
 */
class KeystoreTokenVault(private val alias: String = "aer_core_token_key") : TokenVault {
    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(alias, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    override fun seal(plain: String): String {
        val c = Cipher.getInstance(TRANSFORMATION)
        c.init(Cipher.ENCRYPT_MODE, key())
        val out = c.iv + c.doFinal(plain.encodeToByteArray())
        return Base64.encodeToString(out, Base64.NO_WRAP)
    }

    override fun open(sealed: String): String {
        val all = Base64.decode(sealed, Base64.NO_WRAP)
        val c = Cipher.getInstance(TRANSFORMATION)
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, all, 0, IV_BYTES))
        return c.doFinal(all, IV_BYTES, all.size - IV_BYTES).decodeToString()
    }

    private companion object {
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
    }
}
