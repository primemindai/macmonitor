// CSensors: thin, READ-ONLY C wrappers over private macOS hardware APIs.
// Nothing in this target ever writes an SMC key or needs root.
#ifndef CSENSORS_H
#define CSENSORS_H
#include <stdint.h>
#include <stddef.h>

// ---- AppleSMC (read only: selectors 5 read, 8 key by index, 9 key info) ----
/// Opens the AppleSMC user client. Returns 0 on success and writes the connection handle.
int smc_open(uint32_t *conn);
void smc_close(uint32_t conn);
/// Key info for a 4-char key code. Returns 0 on success.
int smc_key_info(uint32_t conn, uint32_t key, uint32_t *size, uint32_t *type);
/// Reads up to 32 raw bytes of a key whose size came from smc_key_info. Returns 0 on success.
int smc_read_raw(uint32_t conn, uint32_t key, uint32_t size, uint8_t out[32]);
/// Number of keys (from #KEY), 0 on failure.
uint32_t smc_key_count(uint32_t conn);
/// Key code at index. Returns 0 on success.
int smc_key_at(uint32_t conn, uint32_t index, uint32_t *key);

// ---- IOReport (private libIOReport, read only) ----
typedef struct ior_sub ior_sub;
/// Subscribes to the given groups. subgroups[i] may be NULL for "all". Takes a first sample.
ior_sub *ior_create(const char *const *groups, const char *const *subgroups, int n);
void ior_destroy(ior_sub *s);
/// Takes a new sample and stores the delta against the previous one. Returns 0 on success.
/// *seconds gets the wall time between the two samples.
int ior_sample(ior_sub *s, double *seconds, double *continuousSeconds);
/// Like ior_sample, but stores the raw current values (not a delta). For gauges such as display nits.
int ior_sample_absolute(ior_sub *s);
/// Channels in the last delta.
long ior_count(ior_sub *s);
/// format: 1 simple, 2 state, 3 histogram. Strings are truncated to their buffer sizes (128, 64 for unit).
int ior_channel(ior_sub *s, long i, char group[128], char subgroup[128], char name[128], char unit[64], int *format);
int64_t ior_simple_value(ior_sub *s, long i);
int ior_state_count(ior_sub *s, long i);
int64_t ior_state(ior_sub *s, long i, int k, char name[64]);

// ---- HID temperature sensors (IOHIDEventSystemClient, page 0xff00 usage 5) ----
/// Fills up to max names (64 bytes each, packed in one buffer of max*64) and Celsius values.
/// Returns the count, or -1.
int hid_temps(char *names, double *values, int max);
/// Lid angle in degrees from the hinge sensor (page 0x20 usage 0x8A). Returns 0 on success.
int lid_angle(double *degrees);

// ---- NVMe SMART (public IONVMeFamily plug-in) ----
typedef struct {
  int critical_warning, temperature_k, available_spare, spare_threshold, percentage_used;
  double data_units_read, data_units_written, power_cycles, power_on_hours, unsafe_shutdowns, media_errors;
} nvme_smart_t;
/// Reads the SMART log of the first NVMe device. Returns 0 on success.
int nvme_smart_read(nvme_smart_t *out);

#endif
