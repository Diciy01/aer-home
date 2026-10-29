/* Isolated allocator regression: no socket, desktop, clipboard OS API or Dart.
 * Deliberately build THIS executable with Debug CRT and link Release WinPR.
 * All allocations retained by aer_rdp must belong to aer_rdp's allocator.
 */
#if defined(_MSC_VER) && defined(_DEBUG)
#include <crtdbg.h>
#include <process.h>
#endif
#include "../aer_rdp.c"

static unsigned replies = 0;
static UINT capture_reply(CliprdrClientContext* context, const CLIPRDR_FORMAT_DATA_RESPONSE* response)
{
    (void)context;
    if (!(response->common.msgFlags & CB_RESPONSE_OK) || !response->requestedFormatData ||
        response->common.dataLen < 4)
        return ERROR_INVALID_DATA;
    replies++;
    return CHANNEL_RC_OK;
}

#if defined(_MSC_VER) && defined(_DEBUG)
static int crt_failure(int type, char* message, int* value)
{
    (void)value;
    if (type == _CRT_ASSERT || type == _CRT_ERROR)
    {
        /* Preserve the CRT failure in the test log and fail the process.
         * This redirects reporting, not the checks: never continue on error. */
        fprintf(stderr, "FAIL: CRT allocator assertion\n%s\n", message);
        fflush(stderr);
        _exit(86);
    }
    return FALSE;
}
#endif

int main(void)
{
#if defined(_MSC_VER) && defined(_DEBUG)
    _CrtSetReportHook(crt_failure);
#endif
    AerRdp* r = aer_rdp_new();
    if (!r) return 1;
    r->clip_allowed = TRUE;
    CliprdrClientContext context = { 0 };
    context.custom = r;
    context.ClientFormatDataResponse = capture_reply;
    CLIPRDR_FORMAT_DATA_REQUEST request = { 0 };
    request.requestedFormatId = CF_UNICODETEXT;
    const char text[] = "AER TEST \xD0\x9F\xD1\x80\xD0\xB8\xD0\xB2\xD0\xB5\xD1\x82 \xF0\x9F\x8F\xA0";
    const WCHAR remote[] = { 'A', 'E', 'R', 0x041f, 0x0440, 0xD83C, 0xDFE0, 0 };
    CLIPRDR_FORMAT_DATA_RESPONSE response = { 0 };
    response.common.msgFlags = CB_RESPONSE_OK;
    response.common.dataLen = sizeof(remote);
    response.requestedFormatData = (const BYTE*)remote;
    for (unsigned i = 0; i < 1000; i++)
    {
        if (aer_rdp_clip_set(r, text) != 0 || clip_server_data_request(&context, &request) != CHANNEL_RC_OK ||
            clip_server_data_response(&context, &response) != CHANNEL_RC_OK)
            return 2;
        uint64_t seq = 0;
        char* copy = aer_rdp_clip_get(r, &seq);
        if (!copy || seq != i + 1) return 3;
        aer_rdp_mem_free(copy); /* Same allocator as the exported copy. */
    }
    aer_rdp_free(r);
#if defined(_MSC_VER) && defined(_DEBUG)
    if (!_CrtCheckMemory()) return 4;
#endif
    if (replies != 1000) return 5;
    puts("PASS: 1000 clipboard conversions/replacements/copy frees and handle cleanup");
    return 0;
}
