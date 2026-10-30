// hid.c : READ-ONLY HID sensors, ported from research/hid_sensors.c and the lid part of
// research/hid_motion_lid.c. The accelerometer is not touched (it needs a driver change).
#include "CSensors.h"
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);

static CFDictionaryRef match(int page, int usage) {
  CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page), u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
  const void *k[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
  const void *v[] = {p, u};
  CFDictionaryRef m = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFRelease(p); CFRelease(u);
  return m;
}

int hid_temps(char *names, double *values, int max) {
  const int type = 15; // kIOHIDEventTypeTemperature
  IOHIDEventSystemClientRef c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
  if (!c) return -1;
  CFDictionaryRef m = match(0xff00, 5);
  IOHIDEventSystemClientSetMatching(c, m);
  CFRelease(m);
  CFArrayRef svcs = IOHIDEventSystemClientCopyServices(c);
  int count = 0;
  long n = svcs ? CFArrayGetCount(svcs) : 0;
  for (long i = 0; i < n && count < max; i++) {
    IOHIDServiceClientRef s = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(svcs, i);
    CFTypeRef name = IOHIDServiceClientCopyProperty(s, CFSTR("Product"));
    if (!name) continue;
    if (CFGetTypeID(name) != CFStringGetTypeID() ||
        !CFStringGetCString((CFStringRef)name, names + count * 64, 64, kCFStringEncodingUTF8)) { CFRelease(name); continue; }
    CFRelease(name);
    IOHIDEventRef e = IOHIDServiceClientCopyEvent(s, type, 0, 0);
    if (!e) continue;
    values[count] = IOHIDEventGetFloatValue(e, type << 16);
    CFRelease(e);
    count++;
  }
  if (svcs) CFRelease(svcs);
  CFRelease(c);
  return count;
}

int lid_angle(double *degrees) {
  IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, 0);
  if (!m) return -1;
  int page = 0x20, usage = 0x8A;
  CFNumberRef p = CFNumberCreate(NULL, kCFNumberIntType, &page), u = CFNumberCreate(NULL, kCFNumberIntType, &usage);
  const void *k[] = {CFSTR(kIOHIDPrimaryUsagePageKey), CFSTR(kIOHIDPrimaryUsageKey)};
  const void *v[] = {p, u};
  CFDictionaryRef md = CFDictionaryCreate(NULL, k, v, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
  CFRelease(p); CFRelease(u);
  IOHIDManagerSetDeviceMatching(m, md);
  CFRelease(md);
  int rc = -2;
  if (IOHIDManagerOpen(m, kIOHIDOptionsTypeNone) == kIOReturnSuccess) {
    CFSetRef set = IOHIDManagerCopyDevices(m);
    if (set && CFSetGetCount(set) > 0) {
      const void *devs[8] = {0};
      CFIndex cnt = CFSetGetCount(set);
      if (cnt > 8) cnt = 8;
      CFSetGetValues(set, devs);
      IOHIDDeviceRef d = (IOHIDDeviceRef)devs[0];
      if (IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) == kIOReturnSuccess) {
        uint8_t buf[8] = {0};
        CFIndex len = sizeof buf;
        if (IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, 1, buf, &len) == kIOReturnSuccess && len >= 3) {
          *degrees = (double)(buf[1] | (buf[2] << 8));
          rc = 0;
        } else rc = -4;
        IOHIDDeviceClose(d, kIOHIDOptionsTypeNone);
      } else rc = -3;
    }
    if (set) CFRelease(set);
    IOHIDManagerClose(m, kIOHIDOptionsTypeNone);
  }
  CFRelease(m);
  return rc;
}
