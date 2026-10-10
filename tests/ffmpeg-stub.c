/* ONLY FOR OFFLINE TESTS. Simulates one continuously writing RTSP channel. */
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>
#include <string.h>
static volatile sig_atomic_t done = 0;
static void terminate(int sig) {(void)sig; done=1;}
int main(int argc, char **argv) {
  signal(SIGTERM, terminate); signal(SIGINT, terminate);
  if (argc < 3) return 2;
  FILE *fp = fopen(argv[argc-1], "ab");
  if (!fp) return 3;
  do {fputs("some video bytes\n",fp); fflush(fp); sleep(1);} while (!done);
  fclose(fp); return 0;
}
