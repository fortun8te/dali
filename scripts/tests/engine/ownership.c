// Production RTSP queue ownership and HTTP/worker admission, with local test
// substitutes. No network sockets, engine process, or application state.
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <sys/queue.h>
#include <time.h>
#define DPRINTF(...) ((void)0)
#define event_debug(...) ((void)0)
#define event_err(...) abort()
#define EVRTSP_REQUEST 1
#define EVRTSP_REQ_OWN_CONNECTION 1
#define EVTHR_RES_OK 0
#define HTTP_OK 200
#define HTTP_SERVUNAVAIL 503
#define HTTPD_SEND_NO_GZIP 0

enum evrtsp_cmd_type { EVRTSP_REQ_SET_PARAMETER };
struct evrtsp_connection;
struct evrtsp_request {
  TAILQ_ENTRY(evrtsp_request) next;
  struct evrtsp_connection *evcon;
  int flags,kind,type,major,minor;
  char *uri;
};
TAILQ_HEAD(request_queue,evrtsp_request);
struct evrtsp_connection { struct request_queue requests; bool connected; int connect_result; };
static int request_frees,request_dispatches;
static int evrtsp_connected(struct evrtsp_connection *connection) { return connection->connected; }
static int evrtsp_connection_connect(struct evrtsp_connection *connection) { return connection->connect_result; }
static void evrtsp_request_dispatch(struct evrtsp_connection *connection) { request_dispatches++; }
static void evrtsp_request_free(struct evrtsp_request *request) { request_frees++; free(request->uri); free(request); }

struct evthr;
struct event;
struct worker_arg { void(*cb)(void*); void *cb_arg; int delay; struct event *timer; };
static void *worker_threadpool;
static bool worker_rejects;
static struct worker_arg *queued_work;
static void execute(struct evthr *thread,void *arg,void *shared) { assert(0); }
static int evthr_pool_defer(void *pool,void(*cb)(struct evthr*,void*,void*),void *arg) {
  if(worker_rejects) return 1;
  assert(!queued_work); queued_work=arg; return EVTHR_RES_OK;
}
struct httpd_request;
struct module { void(*request)(struct httpd_request*); };
struct httpd_request { char *uri,*path; void *uri_parsed,*evbase,*backend; bool is_async; struct module *module; };
static pthread_mutex_t request_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t request_idle=PTHREAD_COND_INITIALIZER;
static unsigned int requests_in_flight;
static bool requests_stopping;
static void *httpd_allow_origin;
static int reply_code,handled_requests;
static bool preflight,async_mode;
static struct module *selected_module;
static void free_request(struct httpd_request *request) { free(request); }
static int is_cors_preflight(struct httpd_request *request,void *origin) { return preflight; }
static void httpd_send_reply(struct httpd_request *request,int code,const char *text,int flags) { reply_code=code; free_request(request); }
static void httpd_send_error(struct httpd_request *request,int code,const char *text) {
  assert(!request->is_async); reply_code=code; free_request(request);
}
static void httpd_redirect_to(struct httpd_request *request,const char *url) { reply_code=302; free_request(request); }
static void httpd_request_handler_set(struct httpd_request *request) { request->module=selected_module; request->is_async=async_mode; }
static void serve_file(struct httpd_request *request) { handled_requests++; free_request(request); }
static void *httpd_backend_evbase_get(void *backend) { return NULL; }
static void *worker_evbase_get(void) { return NULL; }
static void fake_module(struct httpd_request *request) { handled_requests++; free_request(request); }

/* PRODUCTION_FUNCTIONS */

static void test_rtsp_ownership(void) {
  struct evrtsp_connection connection={0}; TAILQ_INIT(&connection.requests);
  connection.connect_result=-1;
  struct evrtsp_request *request=calloc(1,sizeof *request);
  assert(evrtsp_make_request(&connection,request,EVRTSP_REQ_SET_PARAMETER,"/volume")==-1);
  assert(TAILQ_EMPTY(&connection.requests) && request_frees==1);
  // Failed new requests are removed without touching an existing queued node.
  connection.connect_result=0; request=calloc(1,sizeof *request);
  assert(evrtsp_make_request(&connection,request,EVRTSP_REQ_SET_PARAMETER,"/volume")==0);
  connection.connect_result=-1;
  struct evrtsp_request *other=calloc(1,sizeof *other);
  assert(evrtsp_make_request(&connection,other,EVRTSP_REQ_SET_PARAMETER,"/volume")==-1);
  assert(TAILQ_FIRST(&connection.requests)==request && TAILQ_NEXT(request,next)==NULL && request_frees==2);
  TAILQ_REMOVE(&connection.requests,request,next); evrtsp_request_free(request);
  connection.connected=true; request=calloc(1,sizeof *request);
  assert(evrtsp_make_request(&connection,request,EVRTSP_REQ_SET_PARAMETER,"/volume")==0);
  assert(request_dispatches==1); TAILQ_REMOVE(&connection.requests,request,next); evrtsp_request_free(request);
}
static struct httpd_request *new_request(void) {
  struct httpd_request *request=calloc(1,sizeof *request);
  request->uri="/api/outputs"; request->path=request->uri; request->uri_parsed=request; return request;
}
static void worker_finish(void) {
  struct worker_arg *work=queued_work; queued_work=NULL;
  work->cb(work->cb_arg); free(work->cb_arg); free(work);
}
static void *shutdown_thread(void *arg) { requests_drain(); return NULL; }
static void test_http_ownership(void) {
  struct module module={fake_module}; selected_module=&module; async_mode=true;
  worker_rejects=true; request_cb(new_request(),NULL);
  assert(reply_code==503 && requests_in_flight==0 && !queued_work);
  worker_rejects=false; request_cb(new_request(),NULL);
  assert(requests_in_flight==1 && queued_work); worker_finish(); assert(requests_in_flight==0 && handled_requests==1);
  // The synchronous handler frees hreq before returning. Admission completion
  // uses only its dispatch flag, so ASan catches an accidental dereference.
  async_mode=false; request_cb(new_request(),NULL); assert(requests_in_flight==0 && handled_requests==2);
  async_mode=true; request_cb(new_request(),NULL); assert(requests_in_flight==1);
  pthread_t thread; assert(pthread_create(&thread,NULL,shutdown_thread,NULL)==0);
  for(;;) { pthread_mutex_lock(&request_lock); bool stopping=requests_stopping; pthread_mutex_unlock(&request_lock); if(stopping) break; struct timespec pause={0,1000000}; nanosleep(&pause,NULL); }
  // New admission is rejected while the old worker is still allowed to finish.
  request_cb(new_request(),NULL); assert(reply_code==503 && requests_in_flight==1);
  worker_finish(); assert(pthread_join(thread,NULL)==0); assert(requests_in_flight==0 && handled_requests==3);
}
int main(void) {
  test_rtsp_ownership(); test_http_ownership();
  puts("RTSP failed enqueue ownership, rejected worker admission, freed synchronous requests and shutdown drain passed");
  return 0;
}
