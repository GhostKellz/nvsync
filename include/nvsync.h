/**
 * nvsync - VRR/G-Sync Management for Linux Gaming
 *
 * C API for controlling Variable Refresh Rate, G-Sync, and frame limiting
 * on NVIDIA GPUs under Linux.
 *
 * Usage:
 *   nvsync_ctx_t ctx = nvsync_init();
 *   if (ctx) {
 *       nvsync_scan(ctx);
 *       nvsync_status_t status;
 *       nvsync_get_status(ctx, &status);
 *       printf("Displays: %d, VRR capable: %d\n",
 *              status.display_count, status.vrr_capable_count);
 *       nvsync_destroy(ctx);
 *   }
 */

#ifndef NVSYNC_H
#define NVSYNC_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Version: 0.2.0 */
#define NVSYNC_VERSION_MAJOR 0
#define NVSYNC_VERSION_MINOR 2
#define NVSYNC_VERSION_PATCH 0
#define NVSYNC_VERSION ((NVSYNC_VERSION_MAJOR << 16) | (NVSYNC_VERSION_MINOR << 8) | NVSYNC_VERSION_PATCH)

/**
 * Opaque context handle
 */
typedef void* nvsync_ctx_t;

/**
 * Result codes
 */
typedef enum {
    NVSYNC_SUCCESS = 0,
    NVSYNC_ERROR_INVALID_HANDLE = -1,
    NVSYNC_ERROR_SCAN_FAILED = -2,
    NVSYNC_ERROR_NO_BACKEND = -3,
    NVSYNC_ERROR_DISPLAY_NOT_FOUND = -4,
    NVSYNC_ERROR_INVALID_PARAM = -5,
    NVSYNC_ERROR_NOT_SUPPORTED = -6,
    NVSYNC_ERROR_UNKNOWN = -99
} nvsync_result_t;

/**
 * VRR mode enumeration
 */
typedef enum {
    NVSYNC_VRR_OFF = 0,
    NVSYNC_VRR_GSYNC = 1,
    NVSYNC_VRR_GSYNC_COMPATIBLE = 2,
    NVSYNC_VRR_VRR = 3,
    NVSYNC_VRR_UNKNOWN = 4
} nvsync_vrr_mode_t;

/**
 * Connection type enumeration
 */
typedef enum {
    NVSYNC_CONN_DISPLAYPORT = 0,
    NVSYNC_CONN_HDMI = 1,
    NVSYNC_CONN_DVI = 2,
    NVSYNC_CONN_VGA = 3,
    NVSYNC_CONN_INTERNAL = 4,
    NVSYNC_CONN_UNKNOWN = 5
} nvsync_connection_t;

/**
 * Display information
 */
typedef struct {
    char name[64];                  /* Display name */
    char connector[64];             /* Connector identifier (e.g., "DP-0") */
    nvsync_connection_t connection_type;
    uint32_t current_hz;            /* Current refresh rate */
    uint32_t min_hz;                /* Minimum VRR refresh rate */
    uint32_t max_hz;                /* Maximum VRR refresh rate */
    bool vrr_capable;               /* Supports any form of VRR */
    bool gsync_capable;             /* Native G-Sync module */
    bool gsync_compatible;          /* Adaptive sync / G-Sync Compatible */
    bool lfc_supported;             /* Low Framerate Compensation */
    bool vrr_enabled;               /* VRR currently enabled */
    nvsync_vrr_mode_t current_mode; /* Current VRR mode */
    uint32_t width;                 /* Horizontal resolution */
    uint32_t height;                /* Vertical resolution */
} nvsync_display_t;

/**
 * System VRR status
 */
typedef struct {
    bool nvidia_detected;           /* NVIDIA GPU present */
    char driver_version[32];        /* Driver version string */
    uint32_t display_count;         /* Number of displays */
    uint32_t vrr_capable_count;     /* Displays with VRR capability */
    uint32_t vrr_enabled_count;     /* Displays with VRR enabled */
    char compositor[32];            /* Detected compositor name */
    bool is_wayland;                /* Running under Wayland */
} nvsync_status_t;

/**
 * Frame limiter configuration
 */
typedef struct {
    bool enabled;                   /* Frame limiting enabled */
    uint32_t target_fps;            /* Target frame rate */
    int mode;                       /* 0=GPU, 1=CPU, 2=present_wait */
} nvsync_framelimit_t;

/* ============================================================================
 * Context Management
 * ============================================================================ */

/**
 * Initialize nvsync context
 *
 * @return Context handle, or NULL on failure
 */
nvsync_ctx_t nvsync_init(void);

/**
 * Destroy nvsync context and free all resources
 *
 * @param ctx Context handle
 */
void nvsync_destroy(nvsync_ctx_t ctx);

/**
 * Get library version as packed integer (major << 16 | minor << 8 | patch)
 *
 * @return Version number
 */
uint32_t nvsync_get_version(void);

/* ============================================================================
 * Display Detection
 * ============================================================================ */

/**
 * Scan for connected displays
 *
 * Detects all connected displays and their VRR capabilities.
 *
 * @param ctx Context handle
 * @return NVSYNC_SUCCESS on success
 */
nvsync_result_t nvsync_scan(nvsync_ctx_t ctx);

/**
 * Get number of detected displays
 *
 * @param ctx Context handle
 * @return Number of displays, or -1 on error
 */
int nvsync_get_display_count(nvsync_ctx_t ctx);

/**
 * Get display information by index
 *
 * @param ctx Context handle
 * @param index Display index (0-based)
 * @param out_display Pointer to display structure to fill
 * @return NVSYNC_SUCCESS on success
 */
nvsync_result_t nvsync_get_display(
    nvsync_ctx_t ctx,
    uint32_t index,
    nvsync_display_t* out_display
);

/**
 * Get system VRR status
 *
 * @param ctx Context handle
 * @param out_status Pointer to status structure to fill
 * @return NVSYNC_SUCCESS on success
 */
nvsync_result_t nvsync_get_status(nvsync_ctx_t ctx, nvsync_status_t* out_status);

/* ============================================================================
 * VRR Control
 * ============================================================================ */

/**
 * Enable VRR on a display
 *
 * @param ctx Context handle
 * @param display_name Display name/connector (NULL for all displays)
 * @return NVSYNC_SUCCESS on success
 */
nvsync_result_t nvsync_enable_vrr(nvsync_ctx_t ctx, const char* display_name);

/**
 * Disable VRR on a display
 *
 * @param ctx Context handle
 * @param display_name Display name/connector (NULL for all displays)
 * @return NVSYNC_SUCCESS on success
 */
nvsync_result_t nvsync_disable_vrr(nvsync_ctx_t ctx, const char* display_name);

/**
 * Get VRR range string for a display (e.g., "48-144Hz")
 *
 * @param ctx Context handle
 * @param index Display index
 * @param out_buf Buffer to write range string
 * @param buf_len Buffer length
 * @return NVSYNC_SUCCESS on success
 */
nvsync_result_t nvsync_get_vrr_range(
    nvsync_ctx_t ctx,
    uint32_t index,
    char* out_buf,
    uint32_t buf_len
);

/* ============================================================================
 * Frame Limiting
 * ============================================================================ */

/**
 * Set frame rate limit
 *
 * @param ctx Context handle
 * @param target_fps Target FPS (0 to disable)
 * @return NVSYNC_SUCCESS on success
 */
nvsync_result_t nvsync_set_frame_limit(nvsync_ctx_t ctx, uint32_t target_fps);

/**
 * Get current frame limit configuration
 *
 * @param ctx Context handle
 * @param out_config Pointer to config structure to fill
 * @return NVSYNC_SUCCESS on success
 */
nvsync_result_t nvsync_get_frame_limit(nvsync_ctx_t ctx, nvsync_framelimit_t* out_config);

/* ============================================================================
 * Utility
 * ============================================================================ */

/**
 * Check if NVIDIA GPU is present
 *
 * @return true if NVIDIA GPU detected
 */
bool nvsync_is_nvidia_gpu(void);

/**
 * Check if running under Wayland
 *
 * @return true if Wayland session detected
 */
bool nvsync_is_wayland(void);

/**
 * Get last error message
 *
 * @param ctx Context handle
 * @return Null-terminated error string
 */
const char* nvsync_get_last_error(nvsync_ctx_t ctx);

#ifdef __cplusplus
}
#endif

#endif /* NVSYNC_H */
