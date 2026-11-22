/* The rear stream of Surround. The DSP itself is extracted from outputs/airplay.c by
 * rear-surround.sh, so this always tests the production code. */
enum {N=88200};
static uint8_t in[N*4], out[N*4];
static void put(uint8_t*b,int i,int l,int r){b[i*4]=(uint16_t)(int16_t)l&0xff;b[i*4+1]=(uint16_t)(int16_t)l>>8;b[i*4+2]=(uint16_t)(int16_t)r&0xff;b[i*4+3]=(uint16_t)(int16_t)r>>8;}
static int gl(uint8_t*b,int i){return (int16_t)(b[i*4]|(b[i*4+1]<<8));}
static int gr(uint8_t*b,int i){return (int16_t)(b[i*4+2]|(b[i*4+3]<<8));}
static struct rear_state st;
static double rms(const double*x,int n){double s=0;for(int i=0;i<n;i++)s+=x[i]*x[i];return sqrt(s/n);}
static double corr(const double*x,const double*y,int n){double xy=0,xx=0,yy=0;for(int i=0;i<n;i++){xy+=x[i]*y[i];xx+=x[i]*x[i];yy+=y[i]*y[i];}return xy/sqrt(xx*yy+1e-9);}
static double A[N],B[N],C[N],D[N];
static void measure(const char*name,double*rl,double*rr,double*c,int*peak){
  int s=8820,n=N-s,p=0; for(int i=0;i<n;i++){A[i]=gl(out,i+s);B[i]=gr(out,i+s);if(abs(gl(out,i+s))>p)p=abs(gl(out,i+s));if(abs(gr(out,i+s))>p)p=abs(gr(out,i+s));}
  *rl=rms(A,n);*rr=rms(B,n);*c=corr(A,B,n);*peak=p;
  printf("%-22s rearL %7.0f rearR %7.0f corr(L,R) %+.2f peak %d\n",name,*rl,*rr,*c,p);
}
static double rnd(void){return 2.0*rand()/RAND_MAX-1.0;}
int main(void){
  double rl,rr,c; int pk;
  /* 1. mono: the back stays audible, sits under the front, and back L/R do not match */
  rear_state_init(&st,44100); srand(1);
  for(int i=0;i<N;i++){int x=(int)(6000*rnd());put(in,i,x,x);C[i]=x;}
  memcpy(out,in,sizeof out); channel_mix_apply(out,sizeof out,2,16,1,&st,false);
  measure("mono noise",&rl,&rr,&c,&pk);
  double front=rms(C,N);
  assert(rl>front*0.12 && rl<front*0.25); assert(fabs(rl-rr)/rl<0.05); assert(fabs(c)<0.3);
  { int s=8820,n=N-s; for(int i=0;i<n;i++){A[i]=gl(out,i+s);D[i]=C[i+s];} double cf=corr(A,D,n); printf("corr(front, rearL) %+.2f\n",cf); assert(fabs(cf)<0.5); }
  /* 2. direct versus ambient: what differs between channels goes back far louder than
        what is the same in both. This is the whole point of the mix. */
  double mono_rear=rl/front;
  rear_state_init(&st,44100); srand(1);
  for(int i=0;i<N;i++){put(in,i,(int)(6000*rnd()),(int)(6000*rnd()));}
  memcpy(out,in,sizeof out); channel_mix_apply(out,sizeof out,2,16,1,&st,false);
  measure("wide stereo",&rl,&rr,&c,&pk); assert(fabs(c)<0.1);
  double wide_rear=rl/front; printf("ambient over direct in the back: %.1f dB\n",20*log10(wide_rear/mono_rear)); assert(20*log10(wide_rear/mono_rear)>6.0);
  /* 3. a sound panned hard left stays in back left: back right is close to silent */
  rear_state_init(&st,44100);
  for(int i=0;i<N;i++){put(in,i,(int)(6000*rnd()),0);}
  memcpy(out,in,sizeof out); channel_mix_apply(out,sizeof out,2,16,1,&st,false);
  measure("hard left",&rl,&rr,&c,&pk); printf("hard-left separation %.1f dB\n",20*log10(rl/(rr+1e-9))); assert(20*log10(rl/(rr+1e-9))>36);
  rear_state_init(&st,44100);
  for(int i=0;i<N;i++){put(in,i,0,(int)(6000*rnd()));}
  memcpy(out,in,sizeof out); channel_mix_apply(out,sizeof out,2,16,1,&st,false);
  measure("hard right",&rl,&rr,&c,&pk); assert(20*log10(rr/(rl+1e-9))>36);
  /* 4. a steady centred signal settles at the bass gain, with no gain error from the windows */
  rear_state_init(&st,44100); for(int i=0;i<N;i++)put(in,i,10000,10000);
  memcpy(out,in,sizeof out); channel_mix_apply(out,sizeof out,2,16,1,&st,false);
  printf("DC settle L %d R %d\n",gl(out,N-1),gr(out,N-1)); assert(abs(gl(out,N-1)-1600)<=60&&abs(gr(out,N-1)-1600)<=60);
  /* 5. full-scale anti-phase never wraps and stays bounded */
  rear_state_init(&st,44100); for(int i=0;i<N;i++)put(in,i,(i%100<50)?32767:-32768,(i%100<50)?-32768:32767);
  memcpy(out,in,sizeof out); channel_mix_apply(out,sizeof out,2,16,1,&st,false);
  measure("full-scale anti-phase",&rl,&rr,&c,&pk); assert(pk<=32000 && pk>10000);
  /* 6. silence stays silence and leaves no denormals behind */
  memset(out,0,sizeof out); channel_mix_apply(out,sizeof out,2,16,1,&st,false); memset(out,0,sizeof out); channel_mix_apply(out,sizeof out,2,16,1,&st,false);
  for(int i=0;i<N;i+=999){assert(abs(gl(out,i))<=1&&abs(gr(out,i))<=1);} assert(st.spec_re[3]==st.spec_re[3]);
  /* 7. direct mode is an exact passthrough (Surround off and the speaker test depend on it) */
  rear_state_init(&st,44100); st.wet=0; srand(3); for(int i=0;i<N;i++)put(in,i,(int)(9000*rnd()),0);
  memcpy(out,in,sizeof out); channel_mix_apply(out,sizeof out,2,16,1,&st,true); assert(memcmp(in,out,sizeof out)==0);
  /* live switching: a steady signal glides between the mixes, with no step anywhere */
  { rear_state_init(&st,44100); for(int i=0;i<N;i++)put(in,i,10000,10000);
    memcpy(out,in,sizeof out); channel_mix_apply(out,sizeof out,2,16,1,&st,false);
    int settled=gl(out,N-1);
    memcpy(out,in,sizeof out); channel_mix_apply(out,sizeof out,2,16,1,&st,true);
    int worst=abs(gl(out,0)-settled); for(int i=1;i<N;i++){int d=abs(gl(out,i)-gl(out,i-1)); if(d>worst)worst=d;}
    printf("switch off: largest step %d, fully plain after %d frames\n",worst,(int)(1/st.wet_step)); assert(worst<=6); assert(gl(out,N-1)==10000);
    assert(gl(out,(int)(0.05*44100))==10000);
    memcpy(out,in,sizeof out); channel_mix_apply(out,sizeof out,2,16,1,&st,false);
    worst=abs(gl(out,0)-10000); for(int i=1;i<N;i++){int d=abs(gl(out,i)-gl(out,i-1)); if(d>worst)worst=d;}
    printf("switch on: largest step %d\n",worst); assert(worst<=6); }
  /* 8. packet boundaries change nothing (352-frame packets, as the engine sends) */
  { static struct rear_state a,b; static uint8_t w[N*4],p[N*4]; rear_state_init(&a,44100); rear_state_init(&b,44100); srand(4);
    for(int i=0;i<N;i++)put(w,i,(int)(9000*rnd()),(int)(9000*rnd())); memcpy(p,w,sizeof w);
    channel_mix_apply(w,sizeof w,2,16,1,&a,false);
    for(int off=0;off<N;off+=352){int n=(N-off<352)?N-off:352;channel_mix_apply(p+off*4,n*4,2,16,1,&b,false);} assert(memcmp(w,p,sizeof w)==0);}
  /* 9. plain stream, null state, wrong format are untouched */
  rear_state_init(&st,44100); put(in,0,5,-7);
  memcpy(out,in,4); channel_mix_apply(out,4,2,16,0,&st,false); assert(gl(out,0)==5&&gr(out,0)==-7);
  channel_mix_apply(out,4,2,16,1,NULL,false); assert(gl(out,0)==5&&gr(out,0)==-7);
  channel_mix_apply(out,4,2,24,1,&st,false); assert(gl(out,0)==5&&gr(out,0)==-7);
  channel_mix_apply(out,4,1,16,1,&st,false); assert(gl(out,0)==5&&gr(out,0)==-7);
  /* the front stream: normal music passes, what is steered behind is taken out */
  { rear_state_init(&st,44100); srand(1); for(int i=0;i<N;i++){int x=(int)(6000*rnd());put(in,i,x,x);}
    memcpy(out,in,sizeof out); channel_mix_apply(out,sizeof out,2,16,2,&st,false);
    double e=0,f=0; int lag=REAR_FFT_FRAMES; for(int i=8820;i<N;i++){double d=gl(out,i)-gl(in,i-lag); e+=d*d; f+=(double)gl(in,i-lag)*gl(in,i-lag);}
    printf("front on a mono song: error %.1f dB under the song\n",10*log10(e/f)); assert(10*log10(e/f)<-60);
    rear_state_init(&st,44100); srand(1); for(int i=0;i<N;i++){int x=(int)(6000*rnd());put(in,i,x,-x);}
    memcpy(out,in,sizeof out); channel_mix_apply(out,sizeof out,2,16,2,&st,false);
    measure("front, opposite phase",&rl,&rr,&c,&pk); printf("front keeps %.1f dB of a sound steered behind\n",20*log10(rl/front)); assert(20*log10(rl/front)<-12); }
  /* Ordinary width and panned instruments retain their original front image. */
  for (int kind = 0; kind < 3; kind++) {
    double left = 0, right = 0;
    srand(2);
    for (int i = 0; i < N; i++) {
      left += 0.08 * (18000 * rnd() - left);
      right += 0.08 * (18000 * rnd() - right);
      put(in, i, (int)left, kind == 0 ? (int)right : kind == 1 ? 0 : (int)(0.63 * left));
    }
    rear_state_init(&st, 44100);
    memcpy(out, in, sizeof out);
    channel_mix_apply(out, sizeof out, 2, 16, 2, &st, false);
    double error = 0, reference = 0;
    for (int i = 8820; i < N; i++) {
      int at = i - REAR_FFT_FRAMES;
      double dl = gl(out, i) - gl(in, at);
      double dr = gr(out, i) - gr(in, at);
      error += dl * dl + dr * dr;
      reference += (double)gl(in, at) * gl(in, at) + (double)gr(in, at) * gr(in, at);
    }
    double error_db = 10 * log10((error + 1) / reference);
    printf("front mix error, fixture %d: %.1f dB\n", kind, error_db);
    assert(error_db < -30);
  }

  /* Preserve the exact centre even when phase-opposed effects share its bins. */
  srand(7);
  for (int i = 0; i < N; i++) {
    int voice = (int)(8000 * rnd());
    int effect = (int)(15000 * rnd());
    put(in, i, voice + effect, voice - effect);
  }
  rear_state_init(&st, 44100);
  memcpy(out, in, sizeof out);
  channel_mix_apply(out, sizeof out, 2, 16, 2, &st, false);
  for (int i = 8820; i < N; i++) {
    int at = i - REAR_FFT_FRAMES;
    assert(abs(gl(out, i) + gr(out, i) - gl(in, at) - gr(in, at)) <= 1);
  }

  /* Near-full-scale centre runs without the old soft-knee distortion. */
  for (int i = 0; i < N; i++) {
    int sample = (int)(32767 * sin(2 * M_PI * 1200 * i / 44100.0));
    put(in, i, sample, sample);
  }
  rear_state_init(&st, 44100);
  memcpy(out, in, sizeof out);
  channel_mix_apply(out, sizeof out, 2, 16, 2, &st, false);
  for (int i = 8820; i < N; i++) {
    assert(gl(out, i) == gl(in, i - REAR_FFT_FRAMES));
    assert(gr(out, i) == gr(in, i - REAR_FFT_FRAMES));
  }
  /* the circle: all the way round, the loudest corner follows the sound. Each position is
     encoded exactly as SpeakerTestSignal does: side is balance, ahead or behind is phase. */
  { static const struct { const char*name; double deg; int corner; } at[]={{"front right",45,1},{"back right",135,3},{"back left",225,2},{"front left",315,0}};
    enum {M=44100}; static double xi[M],xq[M]; srand(9);
    { double a[4]={0.6923878,0.9360654322959,0.9882295226860,0.9987488452737},b[4]={0.4021921162426,0.8561710882420,0.9722909545651,0.9952884791278},sa[4][4]={{0}},sb[4][4]={{0}},pq=0;
      for(int i=0;i<M;i++){double n=rnd(),x=n; for(int k=0;k<4;k++){double y=a[k]*a[k]*(x+sa[k][3])-sa[k][1]; sa[k][1]=sa[k][0];sa[k][0]=x;sa[k][3]=sa[k][2];sa[k][2]=y;x=y;} xi[i]=x; xq[i]=pq; x=n; for(int k=0;k<4;k++){double y=b[k]*b[k]*(x+sb[k][3])-sb[k][1]; sb[k][1]=sb[k][0];sb[k][0]=x;sb[k][3]=sb[k][2];sb[k][2]=y;x=y;} pq=x; } }
    for(int p=0;p<4;p++){ double th=at[p].deg*M_PI/180,side=sin(th),ahead=cos(th),bal=(side+1)*M_PI/4,ph=(1-ahead)*M_PI/2;
      static uint8_t fin[M*4],fo[M*4],ro[M*4]; for(int i=0;i<M;i++) put(fin,i,(int)(6000*cos(bal)*xi[i]*sqrt(2)),(int)(6000*sin(bal)*(cos(ph)*xi[i]+sin(ph)*xq[i])*sqrt(2)));
      memcpy(fo,fin,sizeof fo); memcpy(ro,fin,sizeof ro); rear_state_init(&st,44100); channel_mix_apply(fo,sizeof fo,2,16,2,&st,false); rear_state_init(&st,44100); channel_mix_apply(ro,sizeof ro,2,16,1,&st,false);
      double e[4]={0,0,0,0}; for(int i=8820;i<M;i++){ double v[4]={gl(fo,i),gr(fo,i),gl(ro,i),gr(ro,i)}; for(int k=0;k<4;k++)e[k]+=v[k]*v[k]; }
      int best=0; for(int k=1;k<4;k++) if(e[k]>e[best])best=k;
      printf("%-12s FL %5.1f FR %5.1f BL %5.1f BR %5.1f dB -> loudest %d\n",at[p].name,10*log10(e[0]+1)-80,10*log10(e[1]+1)-80,10*log10(e[2]+1)-80,10*log10(e[3]+1)-80,best);
      assert(best==at[p].corner);
      /* front and back must differ enough to hear the sound move, not just win by a hair */
      int across=at[p].corner^2; printf("  %.1f dB over the same side of the other pair\n",10*log10((e[at[p].corner]+1)/(e[across]+1))); assert(10*log10((e[at[p].corner]+1)/(e[across]+1))>3.0); } }
  /* 10. other sample rates stay in bounds */
  rear_state_init(&st,192000); assert(st.delay<REAR_HISTORY_FRAMES&&st.allpass_len[1][1]<REAR_ALLPASS_FRAMES);
  rear_state_init(&st,0); assert(st.allpass_len[0][0]>=1);
  printf("rear surround: all checks passed\n");
  return 0;
}
