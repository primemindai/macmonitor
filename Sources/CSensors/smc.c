// smc.c : READ-ONLY AppleSMC user client, ported from research/smc_dump.c.
// Only the read (5), key-by-index (8) and key-info (9) sub-commands are used. Never write.
#include "CSensors.h"
#include <IOKit/IOKitLib.h>
#include <string.h>

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
  uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo;
  char result, status, data8; uint32_t data32; unsigned char bytes[32];
} SMCParam;
enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCGetKeyFromIndex = 8, kSMCGetKeyInfo = 9 };

static kern_return_t call(io_connect_t c, SMCParam *in, SMCParam *out) {
  size_t sz = sizeof(SMCParam);
  return IOConnectCallStructMethod(c, kSMCHandleYPCEvent, in, sizeof(SMCParam), out, &sz);
}

int smc_open(uint32_t *conn) {
  io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
  if (!svc) return -1;
  io_connect_t c = 0;
  kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &c);
  IOObjectRelease(svc);
  if (kr != KERN_SUCCESS) return -2;
  *conn = c;
  return 0;
}

void smc_close(uint32_t conn) { if (conn) IOServiceClose(conn); }

int smc_key_info(uint32_t conn, uint32_t key, uint32_t *size, uint32_t *type) {
  SMCParam in = {0}, out = {0};
  in.key = key; in.data8 = kSMCGetKeyInfo;
  if (call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return -1;
  *size = out.keyInfo.dataSize; *type = out.keyInfo.dataType;
  return 0;
}

int smc_read_raw(uint32_t conn, uint32_t key, uint32_t size, uint8_t out32[32]) {
  SMCParam in = {0}, out = {0};
  in.key = key; in.keyInfo.dataSize = size; in.data8 = kSMCReadKey;
  if (call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return -2;
  memcpy(out32, out.bytes, 32);
  return 0;
}

uint32_t smc_key_count(uint32_t conn) {
  uint32_t size = 0, type = 0; uint8_t b[32];
  uint32_t k = ('#' << 24) | ('K' << 16) | ('E' << 8) | 'Y';
  if (smc_key_info(conn, k, &size, &type) || smc_read_raw(conn, k, size, b)) return 0;
  return ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
}

int smc_key_at(uint32_t conn, uint32_t index, uint32_t *key) {
  SMCParam in = {0}, out = {0};
  in.data8 = kSMCGetKeyFromIndex; in.data32 = index;
  if (call(conn, &in, &out) != KERN_SUCCESS || out.result != 0) return -1;
  *key = out.key;
  return 0;
}
