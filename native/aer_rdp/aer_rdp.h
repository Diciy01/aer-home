/* aer_rdp — a thin C layer over FreeRDP 3 (libfreerdp-client3) for the
 * built-in AER Remote viewer (ADR-017, M14.3). FFI-friendly: plain types,
 * no callbacks into the caller. One handle = one RDP connection running on
 * its own thread; the caller polls state and frames and queues input.
 *
 * Security: the server certificate is accepted only when its SHA-256
 * equals the pin given to aer_rdp_connect (nothing is stored in a known
 * hosts file; FreeRDP's config dir is private to the connection). The
 * clipboard channel is not even loaded when clipboard is not allowed.
 */
#ifndef AER_RDP_H
#define AER_RDP_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define AER_RDP_API __declspec(dllexport)
#else
#define AER_RDP_API __attribute__((visibility("default")))
#endif

enum {
	AER_RDP_IDLE = 0,
	AER_RDP_CONNECTING = 1,
	AER_RDP_CONNECTED = 2,
	AER_RDP_DISCONNECTED = 3, /* ended by us or by the server */
	AER_RDP_FAILED = 4        /* never connected: see aer_rdp_error */
};

typedef struct AerRdp AerRdp;

AER_RDP_API int aer_rdp_version(void);
AER_RDP_API AerRdp* aer_rdp_new(void);
/* Starts connecting on a background thread. cert_sha256: hex, colons
 * optional. Returns 0 when started. */
AER_RDP_API int aer_rdp_connect(AerRdp* r, const char* host, int port, const char* user,
                                const char* password, const char* cert_sha256, int width,
                                int height, int clipboard);
AER_RDP_API int aer_rdp_state(AerRdp* r);
/* Last error text (static per handle, valid until the next call). */
AER_RDP_API const char* aer_rdp_error(AerRdp* r);

/* Latest frame (BGRA, top-down). Locks the frame: copy, then unlock.
 * Returns NULL when there is no frame yet. */
AER_RDP_API const uint8_t* aer_rdp_frame_lock(AerRdp* r, int* width, int* height, int* stride,
                                              uint64_t* seq);
AER_RDP_API void aer_rdp_frame_unlock(AerRdp* r);

/* Input (queued, sent from the connection thread). flags are RDP
 * PTR_FLAGS_* for the mouse; scancode is an RDP scancode with 0x100 for
 * extended keys. */
AER_RDP_API void aer_rdp_mouse(AerRdp* r, int flags, int x, int y);
AER_RDP_API void aer_rdp_key(AerRdp* r, int scancode, int down);
AER_RDP_API void aer_rdp_unicode(AerRdp* r, int codepoint, int down);

/* Clipboard (text). set: offer this text to the server. get: the server's
 * latest text (malloc'd copy, free with aer_rdp_mem_free) when its
 * sequence number differs from *seq; NULL otherwise. */
AER_RDP_API int aer_rdp_clip_set(AerRdp* r, const char* utf8);
AER_RDP_API char* aer_rdp_clip_get(AerRdp* r, uint64_t* seq);

AER_RDP_API void aer_rdp_disconnect(AerRdp* r);
/* Disconnects (if needed), joins the thread and frees everything. */
AER_RDP_API void aer_rdp_free(AerRdp* r);

AER_RDP_API void aer_rdp_mem_free(void* p);

#ifdef __cplusplus
}
#endif
#endif
