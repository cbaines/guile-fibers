/*
 * Copyright (C) 2020 Abdulrahman Semrie <hsamireh@gmail.com>
 * Copyright (C) 2020-2022 Aleix Conchillo Flaqué <aconchillo@gmail.com>
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public License
 * as published by the Free Software Foundation; either version 3 of
 * the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */



#ifdef HAVE_CONFIG_H
# include <config.h>
#endif

#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <event2/event.h>
#include <libguile.h>

#if SCM_MAJOR_VERSION == 2
# include <fcntl.h>				  /* O_CLOEXEC */
#endif

struct event_data
{
  int fd;
  short event;
};

struct wait_data
{
  int rv;
  struct event_data *events;
  int maxevents;
};

struct loop_data
{
  struct event_base *base;
  int64_t timeout;
};

struct libevt_data
{
  struct event_base *base;
};


static void
free_libevt (void *ptr)
{
  struct libevt_data *libevt = ptr;
  event_base_free (libevt->base);
  scm_gc_free(libevt, sizeof (struct libevt_data), "libevt_data");
}

static void
cb_func (evutil_socket_t fd, short what, void *arg)
#define FUNC_NAME "primitive-event-loop"
{
  struct wait_data* data = arg;
  int rv = data->rv;

  // In theory, we should never exceed the maximum number of events. This is
  // because every time we add a new FD to monitor we check if we have enough
  // room in our vector and if not we resize it. So, if this condition is true
  // is because those assumptions are wrong and we might be doing something
  // funky.
  if (rv >= data->maxevents)
    SCM_MISC_ERROR ("max events fired on fd(~A)", scm_from_int(fd));

  struct event_data ev_data = { fd, what };
  memcpy (data->events + rv, &ev_data, sizeof (struct event_data));

  data->rv += 1;
}
#undef FUNC_NAME

static SCM
scm_primitive_event_wake (SCM wakefd)
#define FUNC_NAME "primitive-event-wake"
{
  int c_fd;
  char zero = 0;

  c_fd = scm_to_int (wakefd);

  if (write (c_fd, &zero, 1) <= 0 && errno != EWOULDBLOCK && errno != EAGAIN)
    SCM_SYSERROR;

  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

static SCM
scm_primitive_create_event_base (SCM eventsv)
#define FUNC_NAME "primitive-create-event-base"
{
  struct libevt_data *libevt;
  struct wait_data *data;
  struct event_base *base;

  if ((base = event_base_new ()) == NULL)
    SCM_MISC_ERROR ("couldn't allocate event_base", SCM_EOL);

  libevt = (struct libevt_data *) scm_gc_malloc (sizeof (struct libevt_data),
                                                 "libevt_data");
  libevt->base = base;

  data = (struct wait_data *) scm_gc_malloc (sizeof (struct wait_data),
                                             "wait_data");
  data->rv = 0;
  data->events = (struct event_data *) SCM_BYTEVECTOR_CONTENTS (eventsv);
  data->maxevents = SCM_BYTEVECTOR_LENGTH (eventsv) / sizeof (struct event_data);

  return scm_list_2 (scm_from_pointer (libevt, free_libevt),
                     scm_from_pointer (data, NULL));
}
#undef FUNC_NAME

static SCM
scm_primitive_add_event (SCM lst, SCM fd, SCM ev)
#define FUNC_NAME "primitive-add-event"
{
  int c_fd;
  short c_ev;
  struct event *event;
  struct wait_data *data;
  struct libevt_data *libevt;

  c_fd = scm_to_int (fd);
  c_ev = scm_to_short (ev);

  libevt =
    (struct libevt_data *) scm_to_pointer (scm_list_ref (lst, scm_from_int (0)));
  data =
    (struct wait_data *) scm_to_pointer (scm_list_ref (lst, scm_from_int (1)));

  event = event_new (libevt->base, c_fd, c_ev, cb_func, data);
  if (event == NULL)
    SCM_MISC_ERROR ("couldn't allocate event", SCM_EOL);

  // We are adding a persistent event.
  int ret = event_add (event, NULL);
  if (ret == -1)
    SCM_MISC_ERROR ("failed to add event", SCM_EOL);

  // We don't need a finalizer since we want to control when event_del() is
  // called in (primitive-remove-event).
  return scm_from_pointer (event, NULL);
}
#undef FUNC_NAME

static SCM
scm_primitive_remove_event (SCM lst, SCM scm_event)
#define FUNC_NAME "primitive-remove-event"
{
  struct event *event = scm_to_pointer(scm_event);

  int ret = event_del (event);
  if (ret == -1)
    SCM_MISC_ERROR ("failed to delete event", SCM_EOL);

  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

static SCM
scm_primitive_resize (SCM lst, SCM eventsv)
#define FUNC_NAME "primitive-resize"
{
  struct wait_data *data;

  data =
    (struct wait_data *) scm_to_pointer (scm_list_ref (lst, scm_from_int (1)));

  data->events = (struct event_data *) SCM_BYTEVECTOR_CONTENTS (eventsv);
  data->maxevents = SCM_BYTEVECTOR_LENGTH (eventsv) / sizeof (struct event_data);

  return SCM_UNSPECIFIED;
}
#undef FUNC_NAME

static uint64_t time_units_per_microsec, microsec_per_time_units;

static void*
run_event_loop (void *p)
#define FUNC_NAME "primitive-event-loop"
{
  int ret;
  struct loop_data *data = p;

  if (data->timeout >= 0)
    {
      struct timeval tv;

      tv.tv_sec = data->timeout / scm_c_time_units_per_second;
      tv.tv_usec =
	time_units_per_microsec > 0
	? ((data->timeout % scm_c_time_units_per_second)
	   / time_units_per_microsec)
	: ((data->timeout % scm_c_time_units_per_second)
	   * microsec_per_time_units);

      ret = event_base_loopexit (data->base, &tv);
      if (ret == -1)
        SCM_MISC_ERROR ("event loop exit failed", SCM_EOL);
    }

  ret = event_base_loop (data->base, EVLOOP_ONCE);
  if (ret == -1)
    SCM_MISC_ERROR ("event loop failed", SCM_EOL);

  return NULL;
}
#undef FUNC_NAME

static SCM
scm_primitive_event_loop (SCM lst, SCM wakefd, SCM wokefd, SCM timeout)
#define FUNC_NAME "primitive-event-loop"
{
  int c_wakefd;
  int c_wokefd;
  int result = 0;
  int64_t c_timeout;

  c_wakefd = scm_to_int (wakefd);
  c_wokefd = scm_to_int (wokefd);
  c_timeout = scm_to_int64 (timeout);

  struct libevt_data *libevt =
    (struct libevt_data *) scm_to_pointer (scm_list_ref (lst, scm_from_int (0)));
  struct wait_data *data =
    (struct wait_data *) scm_to_pointer (scm_list_ref (lst, scm_from_int (1)));

  if (data == NULL)
    scm_wrong_type_arg_msg ("event-loop", 1,
                            scm_list_ref (lst, scm_from_int (1)),
                            "event wait_data is null");

  if (c_timeout != 0 && scm_c_prepare_to_wait_on_fd (c_wakefd))
    data->rv = 0;
  else
    {
      struct loop_data loop_data = { libevt->base, c_timeout };

      if (c_timeout != 0)
        scm_without_guile (run_event_loop, &loop_data);
      else
        run_event_loop (&loop_data);

      if (c_timeout != 0)
        scm_c_wait_finished ();

      for (int i = 0; i < data->rv; i++)
        {
          /* Sometimes we want to wake up the loop event and we do so by writing
           * into a write pipe (see scm_primitive_event_wake). Those writes end
           * up in the read pipe and since those are not real events we just
           * want to ignore them and drain them as we do below.
           */
          if (data->events[i].fd == c_wokefd)
            {
              /* This is just a random size to read from the read pipe. */
              char zeroes[32];
              /* Remove wake fd from result set.  */
              data->rv--;
              memmove (data->events + i,
                       data->events + i + 1,
                       (data->rv - i) * sizeof (struct event_data));
              /* Drain fd and ignore errors. */
              while (read (c_wokefd, zeroes, sizeof zeroes) == sizeof zeroes)
                {
                  /* intentionally empty */
                }
              break;
            }
        }
    }

  // Number of events triggered.
  result = data->rv;

  // Reset for next run loop.
  data->rv = 0;

  return scm_from_int (result);
}

#undef FUNC_NAME

void
init_fibers_libevt (void)
{
  time_units_per_microsec = scm_c_time_units_per_second / 1000000;
  microsec_per_time_units = 1000000 / scm_c_time_units_per_second;

  scm_c_define_gsubr ("primitive-event-wake", 1, 0, 0,
                      scm_primitive_event_wake);
  scm_c_define_gsubr ("primitive-create-event-base", 1, 0, 0,
                      scm_primitive_create_event_base);
  scm_c_define_gsubr ("primitive-add-event", 3, 0, 0,
                      scm_primitive_add_event);
  scm_c_define_gsubr ("primitive-remove-event", 2, 0, 0,
                      scm_primitive_remove_event);
  scm_c_define_gsubr ("primitive-resize", 2, 0, 0,
                      scm_primitive_resize);
  scm_c_define_gsubr ("primitive-event-loop", 4, 0, 0,
                      scm_primitive_event_loop);

  scm_c_define ("%sizeof-struct-event",
                scm_from_size_t (sizeof (struct event_data)));
  scm_c_define ("%offsetof-struct-event-ev",
                scm_from_size_t (offsetof (struct event_data, event)));
  scm_c_define ("EVREAD", scm_from_int (EV_READ));
  scm_c_define ("EVWRITE", scm_from_int (EV_WRITE));
  scm_c_define ("EVPERSIST", scm_from_int (EV_PERSIST));
  scm_c_define ("EVCLOSED", scm_from_int (EV_CLOSED));

  /* Corresponding events, compared to epoll, found at
     https://github.com/libevent/libevent/blob/master/epoll.c  */
  scm_c_define ("EVENTS_IMPL_READ", scm_from_int (EV_READ | EV_CLOSED));
  scm_c_define ("EVENTS_IMPL_WRITE", scm_from_int (EV_WRITE));
  scm_c_define ("EVENTS_IMPL_CLOSED_OR_ERROR", scm_from_int (EV_READ | EV_WRITE));

#if SCM_MAJOR_VERSION == 2
  /* Guile 2.2.7 lacks a definition for O_CLOEXEC.  */
  scm_c_define ("O_CLOEXEC", scm_from_int (O_CLOEXEC));
#endif
}

/*
  Local Variables:
  c-file-style: "gnu"
  End:
*/
