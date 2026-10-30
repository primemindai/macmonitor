// nvme.c : READ-ONLY NVMe SMART log via the public IONVMeFamily plug-in, ported from research/nvme_smart.c.
#include "CSensors.h"
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

static double u128(uint64_t v[2]) { return (double)v[0] + (double)v[1] * 18446744073709551616.0; }

int nvme_smart_read(nvme_smart_t *o) {
  io_iterator_t it;
  if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeBlockStorageDevice"), &it)) return -1;
  io_service_t s;
  int rc = -2;
  while (rc != 0 && (s = IOIteratorNext(it))) {
    IOCFPlugInInterface **plug = NULL;
    SInt32 score;
    kern_return_t kr = IOCreatePlugInInterfaceForService(s, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plug, &score);
    IOObjectRelease(s);
    if (kr || !plug) continue;
    IONVMeSMARTInterface **smart = NULL;
    HRESULT h = (*plug)->QueryInterface(plug, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (h || !smart) { IODestroyPlugInInterface(plug); continue; }
    NVMeSMARTData d = {0};
    if ((*smart)->SMARTReadData(smart, &d) == kIOReturnSuccess) {
      o->critical_warning = d.CRITICAL_WARNING;
      o->temperature_k = d.TEMPERATURE;
      o->available_spare = d.AVAILABLE_SPARE;
      o->spare_threshold = d.AVAILABLE_SPARE_THRESHOLD;
      o->percentage_used = d.PERCENTAGE_USED;
      o->data_units_read = u128(d.DATA_UNITS_READ);
      o->data_units_written = u128(d.DATA_UNITS_WRITTEN);
      o->power_cycles = u128(d.POWER_CYCLES);
      o->power_on_hours = u128(d.POWER_ON_HOURS);
      o->unsafe_shutdowns = u128(d.UNSAFE_SHUTDOWNS);
      o->media_errors = u128(d.MEDIA_ERRORS);
      rc = 0;
    }
    (*smart)->Release(smart);
    IODestroyPlugInInterface(plug);
  }
  IOObjectRelease(it);
  return rc;
}
