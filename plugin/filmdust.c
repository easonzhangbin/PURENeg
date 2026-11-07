/* Film Dust Local: a conservative, local PhotoCraft ABI-v1 filter.
 * Copyright (c) 2026. MIT license; see ../LICENSE.
 * Algorithm design informed by film dust, Copyright (c) 2026 Magnus Holmes,
 * MIT; see ../licenses/ and ../THIRD_PARTY_NOTICES.md.
 * This is a small-speck implementation, not a port of its global models.
 */
typedef unsigned int u32;
typedef unsigned long long u64;
typedef unsigned char u8;
extern unsigned char __heap_base;
static u32 heap;
#define EXPORT __attribute__((visibility("default")))
#define MAX_BYTES (512u * 1024u * 1024u)
#define FILTER_OVERLAP 75
#define STRINGIFY_VALUE(n) #n
#define STRINGIFY(n) STRINGIFY_VALUE(n)

static const char manifest[] =
"{\"id\":\"org.filmdust.local\",\"name\":\"Film Dust Local\",\"version\":\"0.1.1\","
"\"kind\":\"filter\",\"author\":\"Film Dust Local contributors\","
"\"description\":\"Conservative local small-speck repair. RGB/Gray 8/16-bit only. Mark mode writes a visible diagnostic overlay; use a duplicate layer.\","
"\"params\":{"
"\"polarity\":{\"type\":\"choice\",\"options\":[\"bright\",\"dark\"],\"default\":\"bright\"},"
"\"sensitivity\":{\"type\":\"number\",\"min\":0.5,\"max\":2,\"default\":1},"
"\"maxSize\":{\"type\":\"int\",\"min\":2,\"max\":16,\"default\":8,\"unit\":\"px\"},"
"\"strength\":{\"type\":\"number\",\"min\":0,\"max\":1,\"default\":1},"
"\"preview\":{\"type\":\"choice\",\"options\":[\"repair\",\"mark\"],\"default\":\"repair\"}},"
"\"overlap\":" STRINGIFY(FILTER_OVERLAP) ",\"area\":\"content\"}";

EXPORT int pc_abi_version(void) { return 1; }
EXPORT u64 pc_manifest(void) { return ((u64)(sizeof(manifest)-1)<<32)|(u32)(u64)manifest; }
EXPORT u32 pc_alloc(u32 size) {
  if (!heap) heap=((u32)(u64)&__heap_base+15u)&~15u;
  if (size>MAX_BYTES-16u || heap>MAX_BYTES-size-16u) return 0;
  u32 p=heap, end=(heap+size+15u)&~15u;
  u32 pages=__builtin_wasm_memory_size(0), need=(end+65535u)/65536u;
  if(need>pages && __builtin_wasm_memory_grow(0,need-pages)==(u32)-1) return 0;
  heap=end;return p;
}
static float absf(float x){return __builtin_fabsf(x);}
static float clamp(float x,float a,float b){return x<a?a:x>b?b:x;}
static int mini(int a,int b){return a<b?a:b;}
static int maxi(int a,int b){return a>b?a:b;}
static float minf(float a,float b){return a<b?a:b;}
static float maxf(float a,float b){return a>b?a:b;}
static int finitef(float v){return absf(v)<3.0e38f;}
static float median8(float *v){
  for(int i=1;i<8;i++){float t=v[i];int j=i;while(j>0&&v[j-1]>t){v[j]=v[j-1];j--;}v[j]=t;}
  return 0.5f*(v[3]+v[4]);
}
static int same(const char *a,const char*b,int n){for(int i=0;i<n;i++)if(a[i]!=b[i])return 0;return 1;}
static const char *value(const char *p,int n,const char *key,int kl){
  for(int i=0;i+kl+3<n;i++)if(p[i]=='"'&&same(p+i+1,key,kl)&&p[i+1+kl]=='"'){
    int j=i+kl+2;while(j<n&&(p[j]==' '||p[j]=='\n'||p[j]=='\r'||p[j]=='\t'))j++;
    if(j>=n||p[j++]!=':')continue;
    while(j<n&&(p[j]==' '||p[j]=='\n'||p[j]=='\r'||p[j]=='\t'))j++;
    return j<n?p+j:0;
  }return 0;
}
static float number(const char*p,int n,const char*key,int kl,float def){
  const char*s=value(p,n,key,kl);if(!s)return def;
  const char*end=p+n;float v=0,sgn=1;if(s<end&&*s=='-'){sgn=-1;s++;}
  int digits=0;while(s<end&&*s>='0'&&*s<='9'){v=v*10+(*s++-'0');digits++;}
  if(s<end&&*s=='.'){s++;float d=0.1f;while(s<end&&*s>='0'&&*s<='9'){v+=(*s++-'0')*d;d*=0.1f;digits++;}}
  if(s<end&&(*s=='e'||*s=='E')){s++;int neg=0,e=0;if(s<end&&(*s=='-'||*s=='+'))neg=*s++=='-';while(s<end&&*s>='0'&&*s<='9'&&e<30)e=e*10+(*s++-'0');if(e>30)return def;while(e--)v*=neg?0.1f:10.0f;}
  return digits&&finitef(v)?v*sgn:def;
}
static int choice(const char*p,int n,const char*key,int kl,const char*v,int vl){
  const char*s=value(p,n,key,kl);return s&&s+vl+2<=p+n&&*s=='"'&&same(s+1,v,vl)&&s[vl+1]=='"';
}
static inline __attribute__((always_inline)) void prepare_luma(
    const float *src, float *luma, u8 *state, int count, int colors, int alpha) {
  for (int i = 0; i < count; i++, src += colors + alpha) {
    int invalid = !finitef(src[0]);
    float value = src[0];
    if (colors == 3) {
      invalid |= !finitef(src[1]) | !finitef(src[2]);
      value = 0.2126f * src[0] + 0.7152f * src[1] + 0.0722f * src[2];
    }
    if (alpha) invalid |= src[colors] < 0.9999f;
    luma[i] = value;
    state[i] = invalid ? 2 : 0;
  }
}

static inline __attribute__((always_inline)) void find_candidates(
    const float *luma, const u8 *state, u8 *candidate, int width,
    int left, int top, int right, int bottom, int radius, float sensitivity, int sign) {
  const int row = radius * width;
  const int offsets[8] = {-row-radius, -row, -row+radius, -radius, radius, row-radius, row, row+radius};
  const float min_contrast = 0.006f / sensitivity;
  for (int y = top; y < bottom; y++) for (int x = left; x < right; x++) {
    const int i = y * width + x;
    if (state[i] & 2) continue;
    const float center = luma[i];
    float ring[8];
    for (int k = 0; k < 5; k++) ring[k] = luma[i + offsets[k]];

    // With five known samples, both middle values of the eight-sample
    // median must be inside their range. This common early exit needs no
    // loads of the other three samples or of any neighbor validity flags.
    // The finite bound also keeps the shortcut safe for out-of-range floats
    // whose addition in the existing median formula could overflow.
    const float bound = sign > 0
      ? minf(minf(minf(ring[0], ring[1]), minf(ring[2], ring[3])), ring[4])
      : maxf(maxf(maxf(ring[0], ring[1]), maxf(ring[2], ring[3])), ring[4]);
    if (absf(bound) < 1.7e38f && sign * (center - bound) < min_contrast) continue;

    for (int k = 5; k < 8; k++) ring[k] = luma[i + offsets[k]];
    int invalid = 0;
    float lo = 2, hi = -1;
    for (int k = 0; k < 8; k++) {
      invalid |= state[i + offsets[k]];
      lo = minf(lo, ring[k]);
      hi = maxf(hi, ring[k]);
    }
    if (invalid & 2) continue;
    const float range = hi - lo;
    const float upper = sign > 0 ? center - lo : hi - center;
    if (range >= 0.22f || upper < min_contrast || upper <= (0.004f + 0.35f * range) / sensitivity) continue;
    const float residual = sign * (center - median8(ring));
    if (residual < min_contrast) continue;
    float differences[8];
    for (int k = 0; k < 8; k++) {
      const int j = i + offsets[k];
      differences[k] = absf(luma[j] - luma[j + 1]);
    }
    const float noise = median8(differences) * 1.0483f;
    const float threshold = (0.004f + 5.5f * noise + 0.35f * range) / sensitivity;
    if (residual > threshold) candidate[i] = 1;
  }
}

/* In-place ABI buffer; scratch is thrown away after each host band. Errors:
 * 1 dimensions/buffer, 2 unsupported format, 3 allocation. */
EXPORT int pc_filter(u32 bp,u32 bl,int W,int H,int C,int format,u32 pp,int pn){
  int depth=format&255,alpha=(format>>8)&1,mode=(format>>16)&255;
  if((depth!=8&&depth!=16)||!((mode==3&&C==3+alpha)||(mode==1&&C==1+alpha)))return 2;
  if(W<=0||H<=0||C<1||C>4||pn<0||pn>65536||(bp&3))return 1;
  u64 count=(u64)(u32)W*(u32)H, bytes=count*(u32)C*4;
  u64 mem=(u64)__builtin_wasm_memory_size(0)*65536u;
  if(count>20000000u||bytes!=bl||(u64)bp+bl>mem||(u64)pp+(u32)pn>mem)return 1;
  const char*params=(const char*)(u64)pp;
  float sensitivity=clamp(number(params,pn,"sensitivity",11,1),0.5f,2);
  float strength=clamp(number(params,pn,"strength",8,1),0,1);
  int size=(int)clamp(number(params,pn,"maxSize",7,8),2,16);
  int sign=choice(params,pn,"polarity",8,"dark",4)?-1:1;
  int mark=choice(params,pn,"preview",7,"mark",4);
  if(strength==0||W<9||H<9)return 0;
  int N=(int)count, colors=C-alpha, radius=maxi(2,(size+1)/2+2), border=radius+3;
  int gx=(int)number(params,pn,"x",1,0),gy=(int)number(params,pn,"y",1,0);
  int canvasW=(int)number(params,pn,"canvasWidth",11,(float)W),canvasH=(int)number(params,pn,"canvasHeight",12,(float)H);
  const int declared_overlap = (int)number(params, pn, "overlap", 7, 0);
  const int overlap = declared_overlap == FILTER_OVERLAP && W > 2 * declared_overlap && H > 2 * declared_overlap
    ? declared_overlap : 0;
  const int output_right = W - overlap, output_bottom = H - overlap;
  // A component touching the output can reach size-1 pixels out of it.
  // The most distant donor is size+25 pixels away and needs a 2-pixel ring.
  // A larger component crossing this margin is rejected on size either way.
  const int candidate_margin = (size - 1) + (size + 25) + 2;
  u32 saved=heap;
  u32 yp=pc_alloc((u32)N*4),cp=pc_alloc((u32)N),vp=pc_alloc((u32)N);
  if(!yp||!cp||!vp){heap=saved;return 3;}
  float*out=(float*)(u64)bp,*src=out,*Y=(float*)(u64)yp;
  u8*cand=(u8*)(u64)cp,*seen=(u8*)(u64)vp;
  int *queue = 0;
  __builtin_memset(cand,0,(u32)N);
  // Dispatch once so luma preparation has fixed channel and alpha offsets.
  switch (C) {
    case 1: prepare_luma(src, Y, seen, N, 1, 0); break;
    case 2: prepare_luma(src, Y, seen, N, 1, 1); break;
    case 3: prepare_luma(src, Y, seen, N, 3, 0); break;
    case 4: prepare_luma(src, Y, seen, N, 3, 1); break;
  }
  const int dx[8]={-1,0,1,-1,1,-1,0,1},dy[8]={-1,-1,-1,0,0,1,1,1};
  int sx=maxi(maxi(border,border-gx),overlap-candidate_margin);
  int ex=mini(mini(W-border,canvasW-border-gx),output_right+candidate_margin);
  int sy=maxi(maxi(border,border-gy),overlap-candidate_margin);
  int ey=mini(mini(H-border,canvasH-border-gy),output_bottom+candidate_margin);
  if (sign > 0) find_candidates(Y, seen, cand, W, sx, sy, ex, ey, radius, sensitivity, 1);
  else find_candidates(Y, seen, cand, W, sx, sy, ex, ey, radius, sensitivity, -1);
  /* Candidate components must fit the selected diameter and be compact;
   * narrow edges/long fibres are intentionally not in scope. */
  for (int y = overlap; y < output_bottom; y++) for (int x = overlap; x < output_right; x++) {
    const int start = y * W + x;
    if (!cand[start] || seen[start]) continue;
    if (!queue) {
      const u32 qp = pc_alloc((u32)N * 4);
      if (!qp) { heap = saved; return 3; }
      queue = (int *)(u64)qp;
    }
    int head=0,tail=1;queue[0]=start;seen[start]=1;
    int x0=start%W,x1=x0,y0=start/W,y1=y0;
    while(head<tail){
      int i=queue[head++],x=i%W,y=i/W;
      x0=mini(x0,x);x1=maxi(x1,x);y0=mini(y0,y);y1=maxi(y1,y);
      for(int k=0;k<8;k++){int xx=x+dx[k],yy=y+dy[k];if(xx<0||yy<0||xx>=W||yy>=H)continue;int j=yy*W+xx;if(cand[j]&&!seen[j]){seen[j]=1;queue[tail++]=j;}}
    }
    int bw=x1-x0+1,bh=y1-y0+1;
    if(bw>size||bh>size||tail>size*size||tail*3<bw*bh||maxi(bw,bh)>3*mini(bw,bh))continue;
    if(x0<60||y0<60||x1>=W-60||y1>=H-60)continue;
    /* Transparent boundaries protect both repairs and donor neighborhoods. */
    int safe=1;for(int y=y0-2;y<=y1+2&&safe;y++)for(int x=x0-2;x<=x1+2;x++)if(seen[y*W+x]&2){safe=0;break;}
    if(!safe)continue;
    if(mark){for(int q=0;q<tail;q++){int i=queue[q];if(colors==1)out[i*C]=src[i*C]+strength*(1-src[i*C]);else{out[i*C]=src[i*C]+strength*(1-src[i*C]);out[i*C+1]=src[i*C+1]+strength*(0.25f-src[i*C+1]);out[i*C+2]=src[i*C+2]*(1-strength);}}continue;}
    // A clean band and a diagnostic preview need no duplicate pixel buffer.
    // For repair keep a pristine source so one patch never feeds another.
    if (src == out) {
      const u32 sp = pc_alloc((u32)bytes);
      if (!sp) { heap = saved; return 3; }
      src = (float *)(u64)sp;
      __builtin_memcpy(src, out, (u32)bytes);
    }
    /* Select real nearby texture by matching a ring around the mark. No
     * source sample belonging to any detected candidate may be copied. */
    float best=1e30f,adjust[3]={0,0,0};int bestDx=0,bestDy=0;
    for(int level=0;level<3;level++)for(int dir=0;dir<8;dir++){
      int distance=maxi(bw,bh)+5+level*10,ox=dx[dir]*distance,oy=dy[dir]*distance;
      if(x0+ox<2||y0+oy<2||x1+ox>=W-2||y1+oy>=H-2)continue;
      int clean=1;for(int q=0;q<tail;q++){int j=queue[q]+oy*W+ox;if(cand[j]||(seen[j]&2)){clean=0;break;}}
      if(!clean)continue;
      float sums[3]={0,0,0},cost=0;int nr=0;
      for(int y=y0-2;y<=y1+2&&clean;y++)for(int x=x0-2;x<=x1+2;x++){
        if(x>=x0&&x<=x1&&y>=y0&&y<=y1)continue;
        int t=y*W+x,d=t+oy*W+ox;if(cand[t]||cand[d]||(seen[d]&2)){clean=0;break;}
        for(int c=0;c<colors;c++){float v=src[t*C+c]-src[d*C+c];sums[c]+=v;cost+=v*v;}nr++;
      }
      if(!clean||nr<8)continue;
      cost=cost/(nr*colors)*(1+0.005f*(absf((float)ox)+absf((float)oy)));
      if(cost<best){best=cost;bestDx=ox;bestDy=oy;for(int c=0;c<colors;c++)adjust[c]=clamp(sums[c]/nr,-0.08f,0.08f);}
    }
    if(best==1e30f)continue;
    for(int q=0;q<tail;q++){int i=queue[q],d=i+bestDy*W+bestDx;for(int c=0;c<colors;c++){float v=clamp(src[d*C+c]+adjust[c],0,1);out[i*C+c]=src[i*C+c]+strength*(v-src[i*C+c]);}}
  }
  heap=saved;return 0;
}
