// nvme_smart.c : read NVMe SMART log via IONVMeFamily user client plug-in (same route as smartmontools on macOS). READ-ONLY.
// build: clang -O2 -framework IOKit -framework CoreFoundation nvme_smart.c -o nvme_smart
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>
#include <stdio.h>
#include <mach/mach_time.h>
static long double u128(uint64_t v[2]){return (long double)v[0]+(long double)v[1]*18446744073709551616.0L;}
int main(){
  mach_timebase_info_data_t tb; mach_timebase_info(&tb); uint64_t t0=mach_absolute_time();
  io_iterator_t it; CFMutableDictionaryRef m=IOServiceMatching("IONVMeBlockStorageDevice");
  if(IOServiceGetMatchingServices(kIOMainPortDefault,m,&it)){printf("no match\n");return 1;}
  io_service_t s; int found=0;
  while((s=IOIteratorNext(it))){ found++;
    IOCFPlugInInterface**plug=NULL; SInt32 score; kern_return_t kr=IOCreatePlugInInterfaceForService(s,kIONVMeSMARTUserClientTypeID,kIOCFPlugInInterfaceID,&plug,&score);
    if(kr||!plug){printf("plugin create failed 0x%x\n",kr);continue;}
    IONVMeSMARTInterface**smart=NULL; HRESULT h=(*plug)->QueryInterface(plug,CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID),(LPVOID*)&smart);
    if(h||!smart){printf("QueryInterface failed\n");continue;}
    NVMeSMARTData d={0}; kr=(*smart)->SMARTReadData(smart,&d);
    if(kr){printf("SMARTReadData failed 0x%x\n",kr);continue;}
    printf("critical_warning %u\ntemperature %u K = %d C\navailable_spare %u%% (threshold %u%%)\npercentage_used %u%%\n",d.CRITICAL_WARNING,d.TEMPERATURE,d.TEMPERATURE-273,d.AVAILABLE_SPARE,d.AVAILABLE_SPARE_THRESHOLD,d.PERCENTAGE_USED);
    printf("data_units_read %.0Lf (= %.2Lf TB)\ndata_units_written %.0Lf (= %.2Lf TB)\n",u128(d.DATA_UNITS_READ),u128(d.DATA_UNITS_READ)*512000/1e12,u128(d.DATA_UNITS_WRITTEN),u128(d.DATA_UNITS_WRITTEN)*512000/1e12);
    printf("host_read_cmds %.0Lf host_write_cmds %.0Lf\ncontroller_busy_min %.0Lf\npower_cycles %.0Lf\npower_on_hours %.0Lf\nunsafe_shutdowns %.0Lf\nmedia_errors %.0Lf\nerror_log_entries %.0Lf\n",
      u128(d.HOST_READ_COMMANDS),u128(d.HOST_WRITE_COMMANDS),u128(d.CONTROLLER_BUSY_TIME),u128(d.POWER_CYCLES),u128(d.POWER_ON_HOURS),u128(d.UNSAFE_SHUTDOWNS),u128(d.MEDIA_ERRORS),u128(d.NUM_ERROR_INFO_LOG_ENTRIES));
    (*smart)->Release(smart); IODestroyPlugInInterface(plug); IOObjectRelease(s);
  }
  printf("# devices %d, cost %.1f ms\n",found,(mach_absolute_time()-t0)*tb.numer/tb.denom/1e6);
}
