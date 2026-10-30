// hid_motion_lid.c : READ-ONLY test of the MacBook lid-angle HID sensor (page 0x20 usage 0x8A) and the SPU accelerometer (page 0xff00 usage 3).
// build: clang -O2 -framework IOKit -framework CoreFoundation hid_motion_lid.c -o hid_motion_lid
#include <IOKit/hid/IOHIDManager.h>
#include <stdio.h>
static int reports=0; static uint8_t last[64]; static CFIndex lastlen=0;
static void cb(void*ctx,IOReturn r,void*sender,IOHIDReportType t,uint32_t id,uint8_t*rep,CFIndex len){reports++;lastlen=len<64?len:64;memcpy(last,rep,lastlen);}
static CFSetRef devs(int page,int usage,IOHIDManagerRef*mo){
  IOHIDManagerRef m=IOHIDManagerCreate(kCFAllocatorDefault,0);
  CFNumberRef p=CFNumberCreate(0,kCFNumberIntType,&page),u=CFNumberCreate(0,kCFNumberIntType,&usage);
  const void*k[]={CFSTR(kIOHIDPrimaryUsagePageKey),CFSTR(kIOHIDPrimaryUsageKey)};const void*v[]={p,u};
  IOHIDManagerSetDeviceMatching(m,CFDictionaryCreate(0,k,v,2,&kCFTypeDictionaryKeyCallBacks,&kCFTypeDictionaryValueCallBacks));
  IOReturn o=IOHIDManagerOpen(m,kIOHIDOptionsTypeNone); printf("IOHIDManagerOpen(page 0x%x usage 0x%x) = 0x%x\n",page,usage,o);
  *mo=m; return IOHIDManagerCopyDevices(m);
}
int main(){
  IOHIDManagerRef m; CFSetRef s=devs(0x20,0x8A,&m);
  if(s&&CFSetGetCount(s)){ IOHIDDeviceRef d[8]; CFSetGetValues(s,(const void**)d);
    IOReturn o=IOHIDDeviceOpen(d[0],kIOHIDOptionsTypeNone);
    uint8_t buf[8]={0}; CFIndex len=sizeof buf; IOReturn r=IOHIDDeviceGetReport(d[0],kIOHIDReportTypeFeature,1,buf,&len);
    printf("lid sensor: open 0x%x getReport 0x%x len %ld bytes %02x %02x %02x -> angle %d deg\n",o,r,len,buf[0],buf[1],buf[2],buf[1]|(buf[2]<<8));
  } else printf("lid sensor: no device\n");
  CFSetRef a=devs(0xff00,3,&m);
  if(a&&CFSetGetCount(a)){ IOHIDDeviceRef d[8]; CFSetGetValues(a,(const void**)d);
    static uint8_t rb[64]; IOHIDDeviceRegisterInputReportCallback(d[0],rb,sizeof rb,cb,NULL);
    IOHIDDeviceScheduleWithRunLoop(d[0],CFRunLoopGetCurrent(),kCFRunLoopDefaultMode);
    IOReturn o=IOHIDDeviceOpen(d[0],kIOHIDOptionsTypeNone); printf("accel open 0x%x\n",o);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,1.0,false);
    printf("accel: %d input reports in 1 s, last len %ld:",reports,lastlen); for(int i=0;i<lastlen&&i<24;i++)printf(" %02x",last[i]); printf("\n");
  } else printf("accel: no device\n");
}
