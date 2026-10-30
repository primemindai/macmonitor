// hid_sensors.c : read IOHIDEventSystemClient sensors (temperature, voltage, current) READ-ONLY.
// build: clang -O2 -framework IOKit -framework CoreFoundation hid_sensors.c -o hid_sensors
// usage: ./hid_sensors [page usage eventType]   default 0xff00 5 15 (temperature)
//   voltage: 0xff08 3 kIOHIDEventTypePower(25)  current: 0xff08 2 25
#include <IOKit/hidsystem/IOHIDEventSystemClient.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>
#include <stdlib.h>
#include <mach/mach_time.h>
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef, CFDictionaryRef);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef, int64_t, int32_t, int64_t);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef, CFStringRef);
extern double IOHIDEventGetFloatValue(IOHIDEventRef, int32_t);
int main(int argc,char**argv){
  int page=0xff00, usage=5, type=15;
  if(argc==4){page=strtol(argv[1],0,0);usage=strtol(argv[2],0,0);type=strtol(argv[3],0,0);}
  uint64_t t0=mach_absolute_time();
  IOHIDEventSystemClientRef c=IOHIDEventSystemClientCreate(kCFAllocatorDefault);
  CFNumberRef p=CFNumberCreate(0,kCFNumberIntType,&page),u=CFNumberCreate(0,kCFNumberIntType,&usage);
  const void*k[]={CFSTR("PrimaryUsagePage"),CFSTR("PrimaryUsage")};const void*v[]={p,u};
  CFDictionaryRef m=CFDictionaryCreate(0,k,v,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks);
  IOHIDEventSystemClientSetMatching(c,m);
  CFArrayRef svcs=IOHIDEventSystemClientCopyServices(c);
  long n=svcs?CFArrayGetCount(svcs):0;printf("# services: %ld\n",n);
  for(long i=0;i<n;i++){
    IOHIDServiceClientRef s=(IOHIDServiceClientRef)CFArrayGetValueAtIndex(svcs,i);
    CFStringRef name=IOHIDServiceClientCopyProperty(s,CFSTR("Product"));
    char nb[128]="(null)";if(name){CFStringGetCString(name,nb,128,kCFStringEncodingUTF8);CFRelease(name);}
    IOHIDEventRef e=IOHIDServiceClientCopyEvent(s,type,0,0);
    double val= e? IOHIDEventGetFloatValue(e,type<<16):-999; if(e)CFRelease(e);
    printf("%-40s %.3f\n",nb,val);
  }
  mach_timebase_info_data_t tb;mach_timebase_info(&tb);
  fprintf(stderr,"# %.1f ms\n",(mach_absolute_time()-t0)*tb.numer/tb.denom/1e6);
}
