// tests whether PROC_PIDTASKINFO / rusage work on root and other-user processes (no root). build: clang proc_taskinfo_test.c -o proc_taskinfo_test
#include <libproc.h>
#include <stdio.h>
#include <sys/resource.h>
int main(){ int pids[]={0,1,396,364,85279}; for(int i=0;i<5;i++){ struct proc_taskinfo ti; int r=proc_pidinfo(pids[i],PROC_PIDTASKINFO,0,&ti,sizeof ti);
  struct rusage_info_v6 ru; int r2=proc_pid_rusage(pids[i],RUSAGE_INFO_V6,(rusage_info_t*)&ru);
  printf("pid %d taskinfo %s (user=%llu) rusage %s\n",pids[i],r==sizeof ti?"OK":"DENIED",r==sizeof ti?ti.pti_total_user:0,r2==0?"OK":"DENIED");}}
