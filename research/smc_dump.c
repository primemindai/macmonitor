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

int main(int argc,char**argv){
  io_service_t svc=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
  if(!svc){fprintf(stderr,"no AppleSMC\n");return 1;}
  kern_return_t kr=IOServiceOpen(svc,mach_task_self(),0,&conn);
  if(kr){fprintf(stderr,"IOServiceOpen failed 0x%x\n",kr);return 1;}
  SMCKeyInfo ki;unsigned char b[32];char o[128],t[5],k[5];
  if(argc==3&&!strcmp(argv[1],"-k")){uint32_t key=str4(argv[2]);int r=readkey(key,&ki,b);if(r){printf("%s ERR %d\n",argv[2],r);return 1;}fmt(&ki,b,o);tostr(ki.dataType,t);printf("%s [%s] %u = %s\n",argv[2],t,ki.dataSize,o);return 0;}
  if(readkey(str4("#KEY"),&ki,b)){fprintf(stderr,"#KEY fail\n");return 1;}
  uint32_t n=((uint32_t)b[0]<<24)|(b[1]<<16)|(b[2]<<8)|b[3];
  printf("# total keys: %u\n",n);
  uint64_t t0=mach_absolute_time();int cnt=0;
  for(uint32_t i=0;i<n;i++){
    SMCParam in={0},out={0};in.data8=kSMCGetKeyFromIndex;in.data32=i;
    if(call(&in,&out)||out.result)continue;
    tostr(out.key,k);
    if(argc>1){int m=0;for(int a=1;a<argc;a++)if(k[0]==argv[a][0])m=1;if(!m)continue;}
    int r=readkey(out.key,&ki,b);tostr(ki.dataType,t);
    if(r){printf("%s [%s] %u = <read err %d>\n",k,t,ki.dataSize,r);continue;}
    fmt(&ki,b,o);printf("%s [%s] %u = %s\n",k,t,ki.dataSize,o);cnt++;
  }
  mach_timebase_info_data_t tb;mach_timebase_info(&tb);
  fprintf(stderr,"# read %d keys in %.1f ms\n",cnt,(mach_absolute_time()-t0)*tb.numer/tb.denom/1e6);
  IOServiceClose(conn);return 0;
}
