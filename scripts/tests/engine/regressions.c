// Test substitutes surround extracted production functions. This fixture never
// opens a network socket or communicates with an OwnTone process.
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#include <ctype.h>
#include <errno.h>
#include <time.h>
#include <sys/types.h>
#include <sys/time.h>
#include <sys/socket.h>

#define MIN(a,b) ((a) < (b) ? (a) : (b))
#define MAX(a,b) ((a) > (b) ? (a) : (b))
#define DPRINTF(...) ((void)0)
#define evutil_timerclear(tv) memset((tv), 0, sizeof(*(tv)))
#define AIRPLAY_STATE_AUTH 1
#define AIRPLAY_STATE_FAILED 2
#define AIRPLAY_STATE_STREAMING 4
#define AIRPLAY_SEQ_CONTINUE 0
#define AIRPLAY_SEQ_ABORT 1
#define RTSP_OK 200
#define HTTP_BADREQUEST 400
#define HTTP_INTERNAL 500
#define HTTP_NOCONTENT 204

struct evrtsp_connection { int placeholder; };
struct event { bool pending; struct airplay_session *session; };
static struct event fake_event;
struct airplay_session {
  const char *devname;
  int state, server_fd, callback_id, reqs_in_flight;
  uint64_t device_id;
  bool volume_failure_pending;
  struct event *deferredev;
  bool supports_encryption, send_blocked;
  struct timespec send_blocked_since;
  uint64_t send_errors_window, packets_sent_window;
  uint64_t retransmit_requests_window, retransmit_packets_window, retransmit_suppressed_window;
  time_t delivery_log_last_sec, feedback_last_ok_sec;
  struct evrtsp_connection *ctrl;
  char *session_url;
};
struct output_device { const char *name; int max_volume; int type; void *session; bool volume_control_failed; };
static struct output_device *test_device;
static struct output_device *outputs_device_get(uint64_t id) { return test_device; }
enum output_device_state { OUTPUT_STATE_FAILED=-1, OUTPUT_STATE_STREAMING=3 };
typedef void(*output_status_cb)(struct output_device *,enum output_device_state);
static int test_command_result, test_completions;
static void *cmdbase;
static int commands_exec_returnvalue(void *base) { return test_command_result; }
static void commands_exec_end(void *base,int result) { test_command_result=result; test_completions++; }
struct output_definition { bool disabled; int(*device_volume_set)(struct output_device *,int); };
static struct output_definition test_output_definition;
static struct output_definition *outputs[]={&test_output_definition};
static int callback_add(struct output_device *device,output_status_cb cb) { return 123; }
static int output_volume_send(struct output_device *device,int callback_id) { assert(!device->volume_control_failed && callback_id==123); return 1; }
static int outputs_sessions_count(void) { return 1; }
static void pb_suspend(void) { assert(0); }
static void device_streaming_cb(struct output_device *device,enum output_device_state state) {}
static void outputs_device_cb_set(struct output_device *device,void(*cb)(struct output_device *,enum output_device_state)) {}
struct rtp_packet { uint8_t *data; size_t data_len; };
struct evrtsp_request { int response_code; char *response_code_line; void *output_headers; };
enum airplay_seq_type { TEST_CONTINUE, TEST_ABORT, TEST_OTHER };
struct airplay_seq_request {
  const char *name, *uri, *content_type;
  bool proceed_on_rtsp_not_ok;
  int rtsp_type;
  enum airplay_seq_type (*response_handler)(struct evrtsp_request *, struct airplay_session *);
  int (*payload_make)(struct evrtsp_request *, struct airplay_session *, void *);
};
struct airplay_seq_ctx {
  struct airplay_seq_request *cur_request;
  void (*on_success)(struct airplay_session *);
  void (*on_error)(struct airplay_session *);
  struct airplay_session *session;
  void *payload_make_arg;
  const char *log_caller;
};
static struct timespec fake_now;
static bool fake_clock_failure;
static int fake_send_error, status_callbacks, failures, deferred_failures;
static int fake_make_result, request_frees;
static bool fail_request_allocation;
static struct evrtsp_request *queued_request;
struct httpd_request { void *query; };
static const char *httpd_query_value_find(void *query,const char *key) {
  if(!strcmp(key,"volume")) return "0";
  if(!strcmp(key,"output_id")) return "12";
  return NULL;
}
static int safe_atoi32(const char *str,int *value) { *value=atoi(str); return 0; }
static int safe_atou64(const char *str,uint64_t *value) { *value=strtoull(str,NULL,10); return 0; }
static int volume_set(int volume,int step) { return test_command_result; }
static int output_volume_set(int volume,int step,uint64_t id) { return test_command_result; }
static int volume_max = 11;
static int volume_max_get(const char *name) { return volume_max; }
static int test_clock_gettime(int clock, struct timespec *out) {
  if (fake_clock_failure) return -1;
  *out = fake_now; return 0;
}
#define clock_gettime test_clock_gettime
static ssize_t test_send(int fd, const void *data, size_t len, int flags) {
  if (fake_send_error) { errno = fake_send_error; return -1; }
  return (ssize_t)len;
}
#define send test_send
static int packet_encrypt(uint8_t **out, size_t *len, struct rtp_packet *pkt, struct airplay_session *session) {
  *out = malloc(pkt->data_len); *len = pkt->data_len; return 0;
}
static void session_status(struct airplay_session *session) { status_callbacks++; }
static void session_failure(struct airplay_session *session) { failures++; session->state = AIRPLAY_STATE_FAILED; }
static int evtimer_add(struct event *event,const struct timeval *time) {
  assert(event && event->session); event->pending=true;
  if (event->session->state==AIRPLAY_STATE_FAILED) deferred_failures++;
  return 0;
}
static void event_prepare(struct airplay_session *session) { fake_event=(struct event){.session=session}; session->deferredev=&fake_event; }
static void deferred_session_failure_cb(int fd,short what,void *arg);
static void event_drain(void) { assert(fake_event.pending); fake_event.pending=false; deferred_session_failure_cb(0,0,fake_event.session); }
static bool socket_nonblocking_called, socket_nonblocking_fails;
static int evutil_make_socket_nonblocking(int fd) { socket_nonblocking_called=true; return socket_nonblocking_fails?-1:0; }
static int test_setsockopt(int fd,int level,int opt,const void *value,socklen_t len) { return 0; }
#define setsockopt test_setsockopt
static void rtsp_close_cb(struct evrtsp_connection *ctrl, void *session) { assert(0); }
static void evrtsp_connection_set_closecb(struct evrtsp_connection *ctrl, void (*cb)(struct evrtsp_connection *, void *), void *arg) {}
static struct evrtsp_request *evrtsp_request_new(void (*cb)(struct evrtsp_request *, void *), void *arg) {
  return fail_request_allocation ? NULL : calloc(1, sizeof(struct evrtsp_request));
}
static void evrtsp_request_free(struct evrtsp_request *req) { request_frees++; free(req); }
static int evrtsp_make_request(struct evrtsp_connection *ctrl, struct evrtsp_request *req, int type, const char *uri) {
  if (fake_make_result < 0) { evrtsp_request_free(req); return -1; }
  queued_request = req; return 0;
}
static int request_headers_add(struct evrtsp_request *req, struct airplay_session *session, int type) { return 0; }
static void evrtsp_add_header(void *headers, const char *key, const char *value) {}
static void sequence_start(enum airplay_seq_type type, struct airplay_session *session, void *arg, const char *caller) { assert(0); }
static void sequence_continue(struct airplay_seq_ctx *ctx);
// Production immediate-failure completion will be queued on the session timer.


struct media_quality { uint32_t sample_rate; };
struct player_source {
  struct media_quality quality;
  uint64_t play_start;
  uint32_t pos_ms, pos_ms_remainder;
};
static struct {
  struct timespec start_ts, pts, last_pts_slew_ts;
  uint32_t pts_slew_count;
  uint64_t pos;
  struct player_source *playing_now;
} pb_session;
static uint64_t pb_tick_debt_ns;
static struct timespec player_timer_res, pb_tick_last, player_tick_interval = {0, 10000000};
static uint64_t pb_tick_window_bursts, pb_tick_window_frames_smoothed, pb_tick_window_max_raw, pb_tick_window_debt_peak_ns;
static bool test_skip_tick;
static uint64_t test_overrun, test_timer_expirations;
static ssize_t test_read(int fd, void *out, size_t len) { memcpy(out, &test_timer_expirations, len); return len; }
#define read test_read
static int clock_gettime_with_res(int clock, struct timespec *out, struct timespec *res) { return test_clock_gettime(clock, out); }
static int timespec_cmp(struct timespec a, struct timespec b) { return a.tv_sec != b.tv_sec ? (a.tv_sec > b.tv_sec ? 1 : -1) : (a.tv_nsec > b.tv_nsec ? 1 : a.tv_nsec < b.tv_nsec ? -1 : 0); }
static struct timespec timespec_sub(struct timespec a, struct timespec b) {
  struct timespec result = {a.tv_sec - b.tv_sec, a.tv_nsec - b.tv_nsec};
  if (result.tv_nsec < 0) { result.tv_nsec += 1000000000; result.tv_sec--; } return result;
}
static struct timespec timespec_add(struct timespec a, struct timespec b) {
  struct timespec result = {a.tv_sec + b.tv_sec, a.tv_nsec + b.tv_nsec};
  if (result.tv_nsec >= 1000000000) { result.tv_nsec -= 1000000000; result.tv_sec++; } return result;
}

/* PRODUCTION_FUNCTIONS */
/* PRODUCTION_TIMING */

static struct timespec ts(int64_t ns) { return (struct timespec){ ns / 1000000000, ns % 1000000000 }; }
static void assert_close(float a, float b) { assert(fabsf(a-b) < 0.0001f); }
static void test_volume(void) {
  struct output_device device = {.name="test", .max_volume=11};
  assert_close(airplay_volume_from_pct(0, "test"), -144);
  assert_close(raop_volume_from_pct(0, &device), -144);
  assert_close(airplay_volume_from_pct(1, "test"), -29.7);
  assert_close(raop_volume_from_pct(1, &device), -29.7);
  assert_close(airplay_volume_from_pct(100, "test"), 0);
  assert_close(raop_volume_from_pct(100, &device), 0);
  assert(airplay_volume_to_pct(&device, "-144") == 0);
  assert(raop_volume_to_pct(&device, "-144") == 0);
  for (int max = 1; max <= 11; max++) {
    volume_max = max; device.max_volume = max;
    for (int value = 1; value <= 100; value++) {
      char string[64];
      snprintf(string, sizeof string, "%.6f", airplay_volume_from_pct(value, "test"));
      assert(airplay_volume_to_pct(&device, string) == value);
      snprintf(string, sizeof string, "%.6f", raop_volume_from_pct(value, &device));
      assert(raop_volume_to_pct(&device, string) == value);
    }
  }
  volume_max = 11; device.max_volume = 11;
  const char *invalid[] = {"nan", "-nan", "inf", "-inf", "", "nonsense", "-10junk", "1"};
  for (unsigned i=0; i<sizeof invalid/sizeof *invalid; i++) {
    assert(airplay_volume_to_pct(&device, invalid[i]) == -1);
    assert(raop_volume_to_pct(&device, invalid[i]) == -1);
  }
}
static void test_backpressure(void) {
  uint8_t data[32] = {0}; struct rtp_packet pkt = {data, sizeof data};
  const int transient[] = {ENOBUFS, EAGAIN, EWOULDBLOCK, EINTR};
  for (unsigned encrypted=0; encrypted<2; encrypted++) {
    for (unsigned i=0; i<sizeof transient/sizeof *transient; i++) {
      struct airplay_session session = {.state=AIRPLAY_STATE_STREAMING, .devname="test", .supports_encryption=encrypted};
      event_prepare(&session); deferred_failures=0; fake_send_error=transient[i]; fake_now=ts(100000000000LL);
      assert(packet_send(&session, &pkt) == -1);
      assert(session.send_blocked && deferred_failures == 0 && session.state == AIRPLAY_STATE_STREAMING);
      fake_now=ts(101499999999LL); assert(packet_send(&session, &pkt) == -1); assert(deferred_failures==0);
      fake_send_error=0; assert(packet_send(&session, &pkt)==0); assert(!session.send_blocked);
      // Recovery resets the clock, so a separate burst gets its own grace.
      fake_send_error=transient[i]; fake_now=ts(103000000000LL); assert(packet_send(&session,&pkt)==-1);
      fake_now=ts(104500000000LL); assert(packet_send(&session,&pkt)==-1); assert(deferred_failures==1);
    }
  }
  struct airplay_session session = {.state=AIRPLAY_STATE_STREAMING,.devname="test"};
  event_prepare(&session); deferred_failures=0; fake_send_error=EHOSTUNREACH; assert(packet_send(&session,&pkt)==-1); assert(deferred_failures==1);
  session.state=AIRPLAY_STATE_STREAMING; deferred_failures=0; fake_send_error=ENOBUFS; fake_clock_failure=true;
  assert(packet_send(&session,&pkt)==-1); assert(deferred_failures==1); fake_clock_failure=false; fake_send_error=0;
}
static struct airplay_seq_ctx *volume_context(struct airplay_session *session, struct airplay_seq_request *request) {
  struct airplay_seq_ctx *ctx=calloc(1,sizeof *ctx);
  ctx->session=session; ctx->cur_request=request; ctx->on_success=session_status; ctx->on_error=volume_command_failure; return ctx;
}
static void test_volume_timeout(void) {
  struct airplay_session session = {.state=AIRPLAY_STATE_STREAMING,.devname="test",.reqs_in_flight=1};
  struct airplay_seq_request requests[2] = {{.name="volume",.uri="/volume",.proceed_on_rtsp_not_ok=AIRPLAY_VOLUME_PROCEED_NON_OK},{0}};
  event_prepare(&session);
  struct output_device device={.name="test",.max_volume=11,.session=&session}; test_device=&device;
  status_callbacks=failures=deferred_failures=0;
  sequence_continue_cb(NULL,volume_context(&session,requests));
  assert(status_callbacks==1 && failures==0 && deferred_failures==0 && session.state==AIRPLAY_STATE_STREAMING && session.reqs_in_flight==0);
  struct httpd_request http={0};
  test_command_result=1; device_volume_cb(&device,OUTPUT_STATE_STREAMING);
  assert(jsonapi_reply_player_volume(&http)==HTTP_INTERNAL && session.state==AIRPLAY_STATE_STREAMING);
  // A rejected RTSP reply and asynchronous connect failure (response_code=0)
  // are control errors too; they must not become apparent HTTP success.
  for(int code=0;code<=500;code+=500) {
    struct evrtsp_request reply={.response_code=code};
    device.volume_control_failed=false; session.reqs_in_flight=1;
    sequence_continue_cb(&reply,volume_context(&session,requests));
    assert(device.volume_control_failed && session.state==AIRPLAY_STATE_STREAMING);
    test_command_result=1; device_volume_cb(&device,OUTPUT_STATE_STREAMING);
    assert(jsonapi_reply_player_volume(&http)==HTTP_INTERNAL);
  }
  // Immediate request construction/connect failure must complete asynchronously
  // without media retirement or a retained request pointing at freed context.
  fake_make_result=-1; session.volume_failure_pending=false; status_callbacks=0;
  sequence_continue(volume_context(&session,requests));
  assert(session.state==AIRPLAY_STATE_STREAMING && deferred_failures==0 && session.volume_failure_pending);
  assert(status_callbacks==0); event_drain(); assert(status_callbacks==1 && device.volume_control_failed);
  test_command_result=1; device_volume_cb(&device,OUTPUT_STATE_STREAMING); assert(test_command_result==-1 && session.state==AIRPLAY_STATE_STREAMING); assert(jsonapi_reply_player_volume(&http)==HTTP_INTERNAL);
  // A later successful output cannot erase an earlier failure in the command.
  device.volume_control_failed=false; device_volume_cb(&device,OUTPUT_STATE_STREAMING); assert(test_command_result==-1);
  test_command_result=1; device_volume_cb(&device,OUTPUT_STATE_STREAMING); assert(test_command_result==0);
  fake_make_result=0; fail_request_allocation=true; session.volume_failure_pending=false;
  sequence_continue(volume_context(&session,requests)); assert(session.volume_failure_pending && session.state==AIRPLAY_STATE_STREAMING);
  fail_request_allocation=false;
  // A real subsequent output-volume dispatch resets the old control error.
  test_output_definition.device_volume_set=output_volume_send;
  assert(outputs_device_volume_set(&device,device_volume_cb)==1 && !device.volume_control_failed);
  // A completion from an old session cannot mark a replacement session failed.
  struct airplay_session replacement={.state=AIRPLAY_STATE_STREAMING};
  device.session=&replacement; volume_command_failure(&session); assert(!device.volume_control_failed);
  device.session=&session;
  // Delivery failure takes precedence over a queued control-only completion.
  deferred_session_failure(&session); event_drain(); assert(failures==1 && session.state==AIRPLAY_STATE_FAILED);
  test_device=NULL;
}
static void test_socket(void) {
  struct airplay_session session={.devname="test"};
  socket_nonblocking_called=false; assert(data_socket_prepare(&session)==0 && socket_nonblocking_called);
  socket_nonblocking_fails=true; assert(data_socket_prepare(&session)==-1); socket_nonblocking_fails=false;
}
static void test_progress(void) {
  struct player_source source={.quality={44100}};
  memset(&pb_session,0,sizeof pb_session); pb_session.playing_now=&source; fake_now=ts(100000000000LL);
  for(int i=0;i<44100;i++) session_update_read(1);
  assert(pb_session.pos==44100 && source.pos_ms==1000 && source.pos_ms_remainder==0);
  source=(struct player_source){.quality={48000}}; pb_session.pos=0;
  for(int i=0;i<48000;i++) session_update_read(1);
  assert(source.pos_ms==1000 && source.pos_ms_remainder==0);
}
static void marker(int64_t captured_ns) { struct timespec *stamp=malloc(sizeof *stamp); *stamp=ts(captured_ns); session_update_read_ts(stamp); }
static void test_pts(void) {
  memset(&pb_session,0,sizeof pb_session); pb_tick_debt_ns=0;
  fake_now=ts(100000000000LL); pb_session.pts=ts(100020000000LL);
  marker(98000000000LL); assert(timespec_cmp(pb_session.pts,fake_now)==0);
  pb_session.pts=ts(100004000000LL); marker(98000000000LL); assert(pb_session.pts.tv_nsec==4000000);
  pb_session.pts=ts(99800000000LL); marker(90000000000LL); assert(pb_session.pts.tv_nsec==800000000);
  fake_now=ts(101000000000LL); marker(90000000000LL); assert(pb_session.pts.tv_nsec==800100000);
  fake_now=ts(102000000000LL); pb_tick_debt_ns=30000000; marker(90000000000LL); assert(pb_session.pts.tv_nsec==800100000);
  pb_tick_debt_ns=0;
}
static void test_timing(void) {
  pb_tick_debt_ns=0; pb_tick_last=ts(100000000000LL); fake_now=ts(100170000000LL);
#ifdef HAVE_TIMERFD
  test_timer_expirations=17;
#endif
  playback_timing_test(0,0,NULL); assert(test_overrun==2 && pb_tick_debt_ns==140000000);
  uint64_t reads=3;
  for(int i=0;i<7;i++) {
#ifdef HAVE_TIMERFD
    test_timer_expirations=1;
#else
    fake_now=timespec_add(fake_now,ts(10000000));
#endif
    playback_timing_test(0,0,NULL); reads+=test_skip_tick?0:test_overrun+1;
  }
  assert(pb_tick_debt_ns==0 && reads==24);
#ifndef HAVE_TIMERFD
  playback_timing_test(0,0,NULL); assert(test_skip_tick && test_overrun==0);
  fake_now=timespec_add(fake_now,ts(1500000000)); playback_timing_test(0,0,NULL); assert(!test_skip_tick && test_overrun==0 && pb_tick_debt_ns==0);
  uint64_t total=0;
  for(int i=0;i<1000;i++) { fake_now=timespec_add(fake_now,ts(10070000)); playback_timing_test(0,0,NULL); total+=test_skip_tick?0:test_overrun+1; }
  assert(total==1007 && pb_tick_debt_ns==0);
#endif
}
int main(int argc, char **argv) {
  const char *only=argc>1?argv[1]:"all";
#define RUN(name,fn) if(!strcmp(only,"all") || !strcmp(only,name)) fn()
  RUN("socket",test_socket); RUN("volume",test_volume); RUN("backpressure",test_backpressure); RUN("timeout",test_volume_timeout);
  RUN("progress",test_progress); RUN("pts",test_pts); RUN("timing",test_timing);
  printf("%s checks passed\n",only); return 0;
}
