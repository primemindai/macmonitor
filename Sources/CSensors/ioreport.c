// ioreport.c : READ-ONLY IOReport subscription, ported from research/ioreport_common.h + ioreport_sample.c.
#include "CSensors.h"
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach_time.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern void IOReportMergeChannels(CFMutableDictionaryRef, CFMutableDictionaryRef, CFTypeRef);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
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

struct ior_sub {
  IOReportSubscriptionRef sub;
  CFMutableDictionaryRef chans;   // requested channels
  CFMutableDictionaryRef subbed;  // subscribed channels
  CFDictionaryRef prev;           // last raw sample
  CFDictionaryRef delta;          // last delta
  CFArrayRef arr;                 // channels array inside delta (not retained separately)
  uint64_t prevTime;
  uint64_t prevCont;              // same, on the clock that keeps counting during sleep
};

// Awake time only: mach_absolute_time stops while the Mac sleeps.
static double now_s(void) {
  static mach_timebase_info_data_t tb;
  if (!tb.denom) mach_timebase_info(&tb);
  return (double)mach_absolute_time() * tb.numer / tb.denom / 1e9;
}

// Wall time including sleep: mach_continuous_time keeps counting while the Mac sleeps.
static double now_cont_s(void) {
  static mach_timebase_info_data_t tb;
  if (!tb.denom) mach_timebase_info(&tb);
  return (double)mach_continuous_time() * tb.numer / tb.denom / 1e9;
}

static void cs(CFStringRef s, char *b, int n) {
  if (!s || !CFStringGetCString(s, b, n, kCFStringEncodingUTF8)) b[0] = 0;
}

ior_sub *ior_create(const char *const *groups, const char *const *subgroups, int n) {
  CFMutableDictionaryRef chans = NULL;
  for (int i = 0; i < n; i++) {
    CFStringRef G = CFStringCreateWithCString(NULL, groups[i], kCFStringEncodingUTF8);
    CFStringRef S = subgroups[i] ? CFStringCreateWithCString(NULL, subgroups[i], kCFStringEncodingUTF8) : NULL;
    CFMutableDictionaryRef c = IOReportCopyChannelsInGroup(G, S, 0, 0, 0);
    CFRelease(G); if (S) CFRelease(S);
    if (!c) continue;
    if (!chans) chans = c; else { IOReportMergeChannels(chans, c, NULL); CFRelease(c); }
  }
  if (!chans) return NULL;
  ior_sub *s = calloc(1, sizeof(ior_sub));
  s->chans = chans;
  s->sub = IOReportCreateSubscription(NULL, chans, &s->subbed, 0, NULL);
  if (!s->sub || !s->subbed) { ior_destroy(s); return NULL; }
  s->prev = IOReportCreateSamples(s->sub, s->subbed, NULL);
  s->prevTime = (uint64_t)(now_s() * 1e9);
  s->prevCont = (uint64_t)(now_cont_s() * 1e9);
  if (!s->prev) { ior_destroy(s); return NULL; }
  return s;
}

void ior_destroy(ior_sub *s) {
  if (!s) return;
  if (s->delta) CFRelease(s->delta);
  if (s->prev) CFRelease(s->prev);
  if (s->subbed) CFRelease(s->subbed);
  if (s->chans) CFRelease(s->chans);
  if (s->sub) CFRelease((CFTypeRef)s->sub);
  free(s);
}

int ior_sample(ior_sub *s, double *seconds, double *continuousSeconds) {
  CFDictionaryRef cur = IOReportCreateSamples(s->sub, s->subbed, NULL);
  if (!cur) return -1;
  uint64_t t = (uint64_t)(now_s() * 1e9);
  uint64_t tc = (uint64_t)(now_cont_s() * 1e9);
  CFDictionaryRef d = IOReportCreateSamplesDelta(s->prev, cur, NULL);
  CFRelease(s->prev);
  s->prev = cur;
  *seconds = (double)(t - s->prevTime) / 1e9;
  s->prevTime = t;
  *continuousSeconds = (double)(tc - s->prevCont) / 1e9;
  s->prevCont = tc;
  if (s->delta) { CFRelease(s->delta); s->delta = NULL; s->arr = NULL; }
  if (!d) return -2;
  s->delta = d;
  s->arr = CFDictionaryGetValue(d, CFSTR("IOReportChannels"));
  return 0;
}

long ior_count(ior_sub *s) { return s->arr ? CFArrayGetCount(s->arr) : 0; }

static CFDictionaryRef at(ior_sub *s, long i) {
  if (!s->arr || i < 0 || i >= CFArrayGetCount(s->arr)) return NULL;
  return CFArrayGetValueAtIndex(s->arr, i);
}

int ior_channel(ior_sub *s, long i, char group[128], char subgroup[128], char name[128], char unit[64], int *format) {
  CFDictionaryRef ch = at(s, i);
  if (!ch) return -1;
  cs(IOReportChannelGetGroup(ch), group, 128);
  cs(IOReportChannelGetSubGroup(ch), subgroup, 128);
  cs(IOReportChannelGetChannelName(ch), name, 128);
  cs(IOReportChannelGetUnitLabel(ch), unit, 64);
  *format = IOReportChannelGetFormat(ch);
  return 0;
}

int64_t ior_simple_value(ior_sub *s, long i) {
  CFDictionaryRef ch = at(s, i);
  return ch ? IOReportSimpleGetIntegerValue(ch, 0) : 0;
}

int ior_state_count(ior_sub *s, long i) {
  CFDictionaryRef ch = at(s, i);
  return ch ? IOReportStateGetCount(ch) : 0;
}

int64_t ior_state(ior_sub *s, long i, int k, char name[64]) {
  CFDictionaryRef ch = at(s, i);
  if (!ch) { name[0] = 0; return 0; }
  cs(IOReportStateGetNameForIndex(ch, k), name, 64);
  return IOReportStateGetResidency(ch, k);
}

int ior_sample_absolute(ior_sub *s) {
  CFDictionaryRef cur = IOReportCreateSamples(s->sub, s->subbed, NULL);
  if (!cur) return -1;
  if (s->delta) { CFRelease(s->delta); s->delta = NULL; s->arr = NULL; }
  s->delta = cur;
  s->arr = CFDictionaryGetValue(cur, CFSTR("IOReportChannels"));
  return 0;
}
