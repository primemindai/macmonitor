// ioreport_sample.c : subscribe to IOReport groups, take 2 samples, print the delta. READ-ONLY.
// build: clang -O2 -framework CoreFoundation -lIOReport ioreport_sample.c -o ioreport_sample
// usage: ./ioreport_sample <ms> "Group[/SubGroup]" ...   e.g. ./ioreport_sample 1000 "Energy Model" "CPU Stats/CPU Core Performance States"
#include "ioreport_common.h"
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <unistd.h>
#include <mach/mach_time.h>
static double ms_now(){static mach_timebase_info_data_t tb;if(!tb.denom)mach_timebase_info(&tb);return mach_absolute_time()*(double)tb.numer/tb.denom/1e6;}
int main(int argc,char**argv){
  if(argc<3){fprintf(stderr,"usage\n");return 1;}
  int ms=atoi(argv[1]);
  CFMutableDictionaryRef chans=NULL;
  for(int i=2;i<argc;i++){
    char g[256];strcpy(g,argv[i]);char*sg=strchr(g,'/');if(sg)*sg++=0;
    CFStringRef G=CFStringCreateWithCString(0,g,kCFStringEncodingUTF8);
    CFStringRef S=sg?CFStringCreateWithCString(0,sg,kCFStringEncodingUTF8):NULL;
    CFMutableDictionaryRef c=IOReportCopyChannelsInGroup(G,S,0,0,0);
    if(!c){fprintf(stderr,"no group %s\n",argv[i]);continue;}
    if(!chans)chans=c;else IOReportMergeChannels(chans,c,NULL);
  }
  if(!chans)return 1;
  CFMutableDictionaryRef subbed=NULL;
  double t0=ms_now();
  IOReportSubscriptionRef sub=IOReportCreateSubscription(NULL,chans,&subbed,0,NULL);
  if(!sub){fprintf(stderr,"subscribe failed\n");return 1;}
  double t1=ms_now();
  CFDictionaryRef a=IOReportCreateSamples(sub,subbed,NULL);
  double t2=ms_now();
  usleep(ms*1000);
  CFDictionaryRef b=IOReportCreateSamples(sub,subbed,NULL);
  CFDictionaryRef d=getenv("ABS")?b:IOReportCreateSamplesDelta(a,b,NULL);
  fprintf(stderr,"# subscribe %.1f ms, one sample %.1f ms, window %d ms\n",t1-t0,t2-t1,ms);
  CFArrayRef arr=CFDictionaryGetValue(d,CFSTR("IOReportChannels"));
  long n=arr?CFArrayGetCount(arr):0;
  char G[128],S[128],N[128],U[64],st[64];
  for(long i=0;i<n;i++){
    CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i);
    cs(IOReportChannelGetGroup(ch),G,128);cs(IOReportChannelGetSubGroup(ch),S,128);cs(IOReportChannelGetChannelName(ch),N,128);cs(IOReportChannelGetUnitLabel(ch),U,64);
    int f=IOReportChannelGetFormat(ch);
    if(f==1){int64_t v=IOReportSimpleGetIntegerValue(ch,0);
      if(!strcmp(U,"mJ")||!strcmp(U,"uJ")||!strcmp(U,"nJ")){double div=!strcmp(U,"mJ")?1:!strcmp(U,"uJ")?1e3:1e6;
        if(v) printf("%s | %s | %s = %lld %s  -> %.1f mW\n",G,S,N,v,U,(v/div)/(ms/1000.0));}
      else if(v) printf("%s | %s | %s = %lld %s\n",G,S,N,v,U);}
    else if(f==2){int sc=IOReportStateGetCount(ch);int64_t tot=0;for(int k=0;k<sc;k++)tot+=IOReportStateGetResidency(ch,k);
      if(!tot)continue; printf("%s | %s | %s [%d states, %s]:",G,S,N,sc,U);
      for(int k=0;k<sc;k++){int64_t r=IOReportStateGetResidency(ch,k);if(!r)continue;printf(" %s=%.1f%%",cs(IOReportStateGetNameForIndex(ch,k),st,64),100.0*r/tot);}printf("\n");}
    else if(f==3){/* histogram */ printf("%s | %s | %s [histogram fmt]\n",G,S,N);}
  }
}
