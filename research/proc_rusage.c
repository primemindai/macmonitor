// proc_rusage.c : per-process energy / wakeups / P-vs-E time / disk IO via proc_pid_rusage(RUSAGE_INFO_V6). READ-ONLY.
// build: clang -O2 proc_rusage.c -o proc_rusage ; usage: ./proc_rusage [window_ms]
#include <libproc.h>
#include <sys/resource.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <mach/mach_time.h>
typedef struct { pid_t pid; uid_t uid; char name[64]; struct rusage_info_v6 ri; int ok; } P;
static int snap(P*ps,int max,int*okc,int*fail_uid0,int*fail_other){
  pid_t pids[8192]; int n=proc_listallpids(pids,sizeof(pids))/1; int c=0; *okc=*fail_uid0=*fail_other=0;
  for(int i=0;i<n&&c<max;i++){ if(pids[i]<=0 && pids[i]!=0) continue;
    P*p=&ps[c]; memset(p,0,sizeof(*p)); p->pid=pids[i];
    struct proc_bsdshortinfo bi; if(proc_pidinfo(pids[i],PROC_PIDT_SHORTBSDINFO,0,&bi,sizeof bi)==sizeof bi){p->uid=bi.pbsi_uid;strncpy(p->name,bi.pbsi_comm,63);} else {proc_name(pids[i],p->name,63);p->uid=(uid_t)-1;}
    if(proc_pid_rusage(pids[i],RUSAGE_INFO_V6,(rusage_info_t*)&p->ri)==0){p->ok=1;(*okc)++;} else { if(p->uid==0)(*fail_uid0)++; else (*fail_other)++; }
    c++; }
  return c;
}
int main(int argc,char**argv){
  int win=argc>1?atoi(argv[1]):1000; static P a[8192],b[8192]; int ok,f0,fo;
  mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  uint64_t t0=mach_absolute_time(); int na=snap(a,8192,&ok,&f0,&fo); double cost=(mach_absolute_time()-t0)*tb.numer/tb.denom/1e6;
  printf("# procs %d, rusage ok %d, failed root-owned %d, failed other %d, snapshot cost %.1f ms\n",na,ok,f0,fo,cost);
  int rootok=0,otherok=0; uid_t me=getuid(); for(int i=0;i<na;i++) if(a[i].ok){ if(a[i].uid==0)rootok++; else if(a[i].uid!=me)otherok++; }
  printf("# readable: root-owned %d, other-users %d\n",rootok,otherok);
  usleep(win*1000); int nb=snap(b,8192,&ok,&f0,&fo);
  printf("%-7s %-22s %8s %8s %8s %7s %7s %9s %9s %8s %8s\n","pid","name","cpu%","P-ms","E-ms~","energy","mW*","intrWk/s","pkgIdle/s","diskR KB","diskW KB");
  for(int i=0;i<nb;i++){ if(!b[i].ok)continue; P*x=NULL; for(int j=0;j<na;j++) if(a[j].pid==b[i].pid&&a[j].ok){x=&a[j];break;} if(!x)continue;
    struct rusage_info_v6*r1=&x->ri,*r2=&b[i].ri;
    double cpu_ns=(double)((r2->ri_user_time+r2->ri_system_time)-(r1->ri_user_time+r1->ri_system_time))*tb.numer/tb.denom;
    double p_ns=(double)((r2->ri_user_ptime+r2->ri_system_ptime)-(r1->ri_user_ptime+r1->ri_system_ptime))*tb.numer/tb.denom;
    double enj=(double)(r2->ri_energy_nj-r1->ri_energy_nj);
    double cpu=100.0*cpu_ns/(win*1e6); if(cpu<3.0) continue;
    printf("%-7d %-22.22s %7.1f%% %8.0f %8.0f %7.0fmJ %7.0f %9.0f %9.0f %8.0f %8.0f\n",b[i].pid,b[i].name,cpu,p_ns/1e6,(cpu_ns-p_ns)/1e6,enj/1e6,enj/1e6/(win/1000.0),
      (double)(r2->ri_interrupt_wkups-r1->ri_interrupt_wkups)/(win/1000.0),(double)(r2->ri_pkg_idle_wkups-r1->ri_pkg_idle_wkups)/(win/1000.0),
      (r2->ri_diskio_bytesread-r1->ri_diskio_bytesread)/1024.0,(r2->ri_diskio_byteswritten-r1->ri_diskio_byteswritten)/1024.0);
  }
  // show one full record for the biggest process
  for(int i=0;i<nb;i++) if(b[i].ok && b[i].pid==getpid()){struct rusage_info_v6*r=&b[i].ri;
    printf("# self: phys_footprint %llu lifetime_max_footprint %llu billed_energy %llu serviced_energy %llu energy_nj %llu penergy_nj %llu instructions %llu cycles %llu qos_default_ns %llu\n",
      r->ri_phys_footprint,r->ri_lifetime_max_phys_footprint,r->ri_billed_energy,r->ri_serviced_energy,r->ri_energy_nj,r->ri_penergy_nj,r->ri_instructions,r->ri_cycles,r->ri_cpu_time_qos_default);}
}
