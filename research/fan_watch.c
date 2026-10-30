// fan_watch.c : READ-ONLY 1 Hz watch of fans, power and hottest sensors. build: clang -O2 -framework IOKit -framework CoreFoundation fan_watch.c -o fan_watch ; usage ./fan_watch [seconds]
// smc_dump.c : READ-ONLY enumeration of every AppleSMC key and value.
// build: clang -O2 -framework IOKit -framework CoreFoundation smc_dump.c -o smc_dump
// usage: ./smc_dump            (all keys)
//        ./smc_dump T F P      (only keys starting with those letters)
//        ./smc_dump -k F0Ac    (one key)
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <stdlib.h>
#include <math.h>
#include <mach/mach_time.h>
#include <unistd.h>

typedef struct { char major, minor, build, reserved[1]; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize, dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
  uint32_t key; SMCVers vers; SMCPLimit pLimitData; SMCKeyInfo keyInfo;
  char result, status, data8; uint32_t data32; unsigned char bytes[32];
} SMCParam;
enum { kSMCUserClientOpen=0, kSMCHandleYPCEvent=2, kSMCReadKey=5, kSMCGetKeyFromIndex=8, kSMCGetKeyInfo=9 };

static io_connect_t conn;
static uint32_t str4(const char*s){return ((uint32_t)s[0]<<24)|((uint32_t)s[1]<<16)|((uint32_t)s[2]<<8)|(uint32_t)s[3];}
static void tostr(uint32_t v,char*o){o[0]=v>>24;o[1]=v>>16;o[2]=v>>8;o[3]=v;o[4]=0;}
static kern_return_t call(SMCParam*in,SMCParam*out){size_t sz=sizeof(SMCParam);return IOConnectCallStructMethod(conn,kSMCHandleYPCEvent,in,sizeof(SMCParam),out,&sz);}

static int keyinfo(uint32_t key, SMCKeyInfo*ki){SMCParam in={0},out={0};in.key=key;in.data8=kSMCGetKeyInfo;
  if(call(&in,&out)!=KERN_SUCCESS||out.result!=0)return -1;*ki=out.keyInfo;return 0;}
static int readkey(uint32_t key, SMCKeyInfo*ki, unsigned char*buf){
  if(keyinfo(key,ki))return -1;SMCParam in={0},out={0};in.key=key;in.keyInfo.dataSize=ki->dataSize;in.data8=kSMCReadKey;
  if(call(&in,&out)!=KERN_SUCCESS||out.result!=0)return -2;memcpy(buf,out.bytes,32);return 0;}

static void fmt(SMCKeyInfo*ki,unsigned char*b,char*o){
  char t[5];tostr(ki->dataType,t);
  if(!strcmp(t,"flt ")&&ki->dataSize==4){float f;memcpy(&f,b,4);sprintf(o,"%.3f",f);}
  else if(!strcmp(t,"ui8 ")||!strcmp(t,"flag"))sprintf(o,"%u",b[0]);
  else if(!strcmp(t,"si8 "))sprintf(o,"%d",(int8_t)b[0]);
  else if(!strcmp(t,"ui16"))sprintf(o,"%u",(b[0]<<8)|b[1]);
  else if(!strcmp(t,"si16"))sprintf(o,"%d",(int16_t)((b[0]<<8)|b[1]));
  else if(!strcmp(t,"ui32"))sprintf(o,"%u",((uint32_t)b[0]<<24)|(b[1]<<16)|(b[2]<<8)|b[3]);
  else if(!strcmp(t,"ui64")){uint64_t v=0;for(int i=0;i<8;i++)v=(v<<8)|b[i];sprintf(o,"%llu",v);}
  else if(!strcmp(t,"sp78"))sprintf(o,"%.2f",((int16_t)((b[0]<<8)|b[1]))/256.0);
  else if(!strcmp(t,"fpe2"))sprintf(o,"%.2f",((b[0]<<8)|b[1])/4.0);
  else if(!strcmp(t,"ioft")){uint64_t v;memcpy(&v,b,8);sprintf(o,"%.3f",v/65536.0);}
  else if(!strcmp(t,"ch8*")){int n=ki->dataSize<31?ki->dataSize:31;memcpy(o,b,n);o[n]=0;for(int i=0;i<n;i++)if(o[i]<32||o[i]>126)o[i]='.';}
  else {char*p=o;p+=sprintf(p,"hex:");for(unsigned i=0;i<ki->dataSize&&i<16;i++)p+=sprintf(p,"%02x",b[i]);}
}


static double rd(const char*k){SMCKeyInfo ki;unsigned char b[32];if(readkey(str4(k),&ki,b))return NAN;char t[5];tostr(ki.dataType,t);
  if(!strcmp(t,"flt ")){float f;memcpy(&f,b,4);return f;} if(!strcmp(t,"ui8 "))return b[0]; if(!strcmp(t,"ioft")){uint64_t v;memcpy(&v,b,8);return v/65536.0;} return NAN;}
int main(int argc,char**argv){
  io_service_t svc=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));IOServiceOpen(svc,mach_task_self(),0,&conn);
  // gather key lists once
  SMCKeyInfo ki;unsigned char b[32];readkey(str4("#KEY"),&ki,b);uint32_t n=((uint32_t)b[0]<<24)|(b[1]<<16)|(b[2]<<8)|b[3];
  char tp[200][5],tg[100][5];int ntp=0,ntg=0;
  for(uint32_t i=0;i<n;i++){SMCParam in={0},out={0};in.data8=kSMCGetKeyFromIndex;in.data32=i;if(call(&in,&out)||out.result)continue;char k[5];tostr(out.key,k);
    if(k[0]=='T'&&k[1]=='p'&&ntp<200)strcpy(tp[ntp++],k); if(k[0]=='T'&&k[1]=='g'&&ntg<100)strcpy(tg[ntg++],k);}
  int N=argc>1?atoi(argv[1]):8;
  printf("t  F0Ac   F0Tg   F1Ac   F1Tg  F0Md Ftst  PSTR(W) PDTR(W) PPBR(W) maxTp  avgTp  maxTg  TB0T  TaLP  TW0P\n");
  for(int s=0;s<N;s++){double mx=-1,sum=0;int c=0;for(int i=0;i<ntp;i++){double v=rd(tp[i]);if(v>1&&v<150){if(v>mx)mx=v;sum+=v;c++;}}
    double mg=-1;for(int i=0;i<ntg;i++){double v=rd(tg[i]);if(v>1&&v<150&&v>mg)mg=v;}
    printf("%d %6.0f %6.0f %6.0f %6.0f %4.0f %4.0f %8.1f %7.1f %7.2f %6.1f %6.1f %6.1f %5.1f %5.1f %5.1f\n",s,rd("F0Ac"),rd("F0Tg"),rd("F1Ac"),rd("F1Tg"),rd("F0Md"),rd("Ftst"),rd("PSTR"),rd("PDTR"),rd("PPBR"),mx,sum/c,mg,rd("TB0T"),rd("TaLP"),rd("TW0P"));
    fflush(stdout); if(s<N-1)sleep(1);}
}
