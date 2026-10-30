// ioreport_list.c : list every IOReport channel (group / subgroup / name / format / unit) READ-ONLY.
// build: clang -O2 -framework CoreFoundation -lIOReport ioreport_list.c -o ioreport_list
#include "ioreport_common.h"
#include <stdio.h>
int main(){
  CFMutableDictionaryRef all=IOReportCopyAllChannels(0,0);
  if(!all){printf("no channels\n");return 1;}
  CFArrayRef arr=CFDictionaryGetValue(all,CFSTR("IOReportChannels"));
  long n=arr?CFArrayGetCount(arr):0; printf("# channels: %ld\n",n);
  char g[128],sg[128],nm[128],u[64];
  for(long i=0;i<n;i++){CFDictionaryRef ch=CFArrayGetValueAtIndex(arr,i);
    printf("%s | %s | %s | fmt=%d | %s\n",cs(IOReportChannelGetGroup(ch),g,128),cs(IOReportChannelGetSubGroup(ch),sg,128),cs(IOReportChannelGetChannelName(ch),nm,128),IOReportChannelGetFormat(ch),cs(IOReportChannelGetUnitLabel(ch),u,64));}
}
