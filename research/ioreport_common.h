// Private libIOReport declarations (same set used by macmon / asitop / socpowerbuddy).
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>
typedef struct IOReportSubscriptionRef* IOReportSubscriptionRef;
extern CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t, uint64_t);
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern void IOReportMergeChannels(CFMutableDictionaryRef, CFMutableDictionaryRef, CFTypeRef);
extern IOReportSubscriptionRef IOReportCreateSubscription(void*, CFMutableDictionaryRef, CFMutableDictionaryRef*, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int32_t IOReportChannelGetFormat(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);
extern int32_t IOReportArrayGetValueCount(CFDictionaryRef);
extern int64_t IOReportArrayGetValueAtIndex(CFDictionaryRef, int32_t);
static inline const char* cs(CFStringRef s, char*b, int n){ if(!s){b[0]=0;return b;} if(!CFStringGetCString(s,b,n,kCFStringEncodingUTF8))b[0]=0; return b;}
