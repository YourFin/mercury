/*
** Copyright (C) 1998 The University of Melbourne.
** This file may only be copied under the terms of the GNU Library General
** Public License - see the file COPYING.LIB in the Mercury distribution.
*/

/*
** This module defines the signal handlers for memory zones.
** These handlers are invoked when memory is accessed outside of
** the memory zones, or at the protected region at the end of a
** memory zone (if available).
*/

/*---------------------------------------------------------------------------*/

#include "mercury_imp.h"

#ifdef HAVE_SIGCONTEXT_STRUCT
  /*
  ** Some versions of Linux call it struct sigcontext_struct, some call it
  ** struct sigcontext.  The following #define eliminates the differences.
  */
  #define sigcontext_struct sigcontext /* must be before #include <signal.h> */

  /*
  ** On some systems (e.g. most versions of Linux) we need to #define
  ** __KERNEL__ to get sigcontext_struct from <signal.h>.
  ** This stuff must come before anything else that might include <signal.h>,
  ** otherwise the #define __KERNEL__ may not work.
  */
  #define __KERNEL__
  #include <signal.h>	/* must come third */
  #undef __KERNEL__

  /*
  ** Some versions of Linux define it in <signal.h>, others define it in
  ** <asm/sigcontext.h>.  We try both.
  */
  #ifdef HAVE_ASM_SIGCONTEXT
    #include <asm/sigcontext.h>
  #endif 
#else
  #include <signal.h>
#endif

#include <unistd.h>
#include <stdio.h>
#include <string.h>

#ifdef HAVE_SYS_SIGINFO
  #include <sys/siginfo.h>
#endif 

#ifdef	HAVE_MPROTECT
  #include <sys/mman.h>
#endif

#ifdef	HAVE_UCONTEXT
  #include <ucontext.h>
#endif

#ifdef	HAVE_SYS_UCONTEXT
  #include <sys/ucontext.h>
#endif

#include "mercury_imp.h"
#include "mercury_trace.h"
#include "mercury_memory_zones.h"
#include "mercury_memory_handlers.h"

/*---------------------------------------------------------------------------*/

#ifdef HAVE_SIGINFO
  #if defined(HAVE_SIGCONTEXT_STRUCT)
    static	void	complex_sighandler(int, struct sigcontext_struct);
  #elif defined(HAVE_SIGINFO_T)
    static	void	complex_bushandler(int, siginfo_t *, void *);
    static	void	complex_segvhandler(int, siginfo_t *, void *);
  #else
    #error "HAVE_SIGINFO defined but don't know how to get it"
  #endif
#else
  static	void	simple_sighandler(int);
#endif

/*
** round_up(amount, align) returns `amount' rounded up to the nearest
** alignment boundary.  `align' must be a power of 2.
*/

static	void	setup_mprotect(void);
static void	print_dump_stack(void);

#ifdef	HAVE_SIGINFO
  static	bool	try_munprotect(void *address, void *context);
  static	char	*explain_context(void *context);
#endif /* HAVE_SIGINFO */

#define STDERR 2

#if defined(HAVE_MPROTECT) && defined(HAVE_SIGINFO)
	/* try_munprotect is only useful if we have SIGINFO */

/*
** fatal_abort() prints an error message, possibly a stack dump, and then exits.
** It is like fatal_error(), except that it is safe to call
** from a signal handler.
*/

static void 
fatal_abort(void *context, const char *main_msg, int dump)
{
	char	*context_msg;

	context_msg = explain_context(context);
	write(STDERR, main_msg, strlen(main_msg));
	write(STDERR, context_msg, strlen(context_msg));
	MR_trace_report_raw(STDERR);

	if (dump) {
		print_dump_stack();
	}

	_exit(1);
}

static bool 
try_munprotect(void *addr, void *context)
{
	Word *    fault_addr;
	Word *    new_zone;
	MemoryZone *zone;

	fault_addr = (Word *) addr;

	zone = get_used_memory_zones();

	if (memdebug) {
		fprintf(stderr, "caught fault at %p\n", (void *)addr);
	}

	while(zone != NULL) {
		if (memdebug) {
			fprintf(stderr, "checking %s#%d: %p - %p\n",
				zone->name, zone->id, (void *) zone->redzone,
				(void *) zone->top);
		}

		if (zone->redzone <= fault_addr && fault_addr <= zone->top) {

			if (memdebug) {
				fprintf(stderr, "address is in %s#%d redzone\n",
					zone->name, zone->id);
			}

			return zone->handler(fault_addr, zone, context);
		}
		zone = zone->next;
	}

	if (memdebug) {
		fprintf(stderr, "address not in any redzone.\n");
	}

	return FALSE;
} /* end try_munprotect() */

bool 
default_handler(Word *fault_addr, MemoryZone *zone, void *context)
{
    Word *new_zone;
    size_t zone_size;

    new_zone = (Word *) round_up((Unsigned) fault_addr + sizeof(Word), unit);

    if (new_zone <= zone->hardmax) {
	zone_size = (char *)new_zone - (char *)zone->redzone;

	if (memdebug) {
	    fprintf(stderr, "trying to unprotect %s#%d from %p to %p (%x)\n",
	    zone->name, zone->id, (void *) zone->redzone, (void *) new_zone,
	    (int)zone_size);
	}
	if (mprotect((char *)zone->redzone, zone_size,
	    PROT_READ|PROT_WRITE) < 0)
	{
	    char buf[2560];
	    sprintf(buf, "Mercury runtime: cannot unprotect %s#%d zone",
		zone->name, zone->id);
	    perror(buf);
	    exit(1);
	}

	zone->redzone = new_zone;

	if (memdebug) {
	    fprintf(stderr, "successful: %s#%d redzone now %p to %p\n",
		zone->name, zone->id, (void *) zone->redzone,
		(void *) zone->top);
	}
	return TRUE;
    } else {
	char buf[2560];
	if (memdebug) {
	    fprintf(stderr, "can't unprotect last page of %s#%d\n",
		zone->name, zone->id);
	    fflush(stdout);
	}
	sprintf(buf, "\nMercury runtime: memory zone %s#%d overflowed\n",
		zone->name, zone->id);
	fatal_abort(context, buf, TRUE);
    }

    return FALSE;
} /* end default_handler() */

bool 
null_handler(Word *fault_addr, MemoryZone *zone, void *context)
{
	return FALSE;
}

#else
/* not HAVE_MPROTECT || not HAVE_SIGINFO */

static bool 
try_munprotect(void *addr, void *context)
{
	return FALSE;
}

bool 
default_handler(Word *fault_addr, MemoryZone *zone, void *context)
{
	return FALSE;
}

bool 
null_handler(Word *fault_addr, MemoryZone *zone, void *context)
{
	return FALSE;
}

#endif /* not HAVE_MPROTECT || not HAVE_SIGINFO */

#if defined(HAVE_SIGCONTEXT_STRUCT)

void
setup_signal(void)
{
	if (signal(SIGBUS, (void(*)(int)) complex_sighandler) == SIG_ERR)
	{
		perror("cannot set SIGBUS handler");
		exit(1);
	}

	if (signal(SIGSEGV, (void(*)(int)) complex_sighandler) == SIG_ERR)
	{
		perror("cannot set SIGSEGV handler");
		exit(1);
	}
}

static void
complex_sighandler(int sig, struct sigcontext_struct sigcontext)
{
	void *address = (void *) sigcontext.cr2;
  #ifdef PC_ACCESS
	void *pc_at_signal = (void *) sigcontext.PC_ACCESS;
  #endif

	switch(sig) {
		case SIGSEGV:
			/*
			** If we're debugging, print the segv explanation
			** messages before we call try_munprotect.  But if
			** we're not debugging, only print them if
			** try_munprotect fails.
			*/
			if (memdebug) {
				fflush(stdout);
				fprintf(stderr, "\n*** Mercury runtime: "
					"caught segmentation violation ***\n");
			}
			if (try_munprotect(address, &sigcontext)) {
				if (memdebug) {
					fprintf(stderr, "returning from "
						"signal handler\n\n");
				}
				return;
			}
			if (!memdebug) {
				fflush(stdout);
				fprintf(stderr, "\n*** Mercury runtime: "
					"caught segmentation violation ***\n");
			}
			break;

		case SIGBUS:
			fflush(stdout);
			fprintf(stderr, "\n*** Mercury runtime: "
					"caught bus error ***\n");
			break;

		default:
			fflush(stdout);
			fprintf(stderr, "\n*** Mercury runtime: "
					"caught unknown signal %d ***\n", sig);
			break;
	}

  #ifdef PC_ACCESS
	fprintf(stderr, "PC at signal: %ld (%lx)\n",
		(long) pc_at_signal, (long) pc_at_signal);
  #endif
	fprintf(stderr, "address involved: %p\n", address);

	MR_trace_report(stderr);
	print_dump_stack();
	dump_prev_locations();
	fprintf(stderr, "exiting from signal handler\n");
	exit(1);
} /* end complex_sighandler() */

static char *
explain_context(void *the_context)
{
	static	char	buf[100];
  #ifdef PC_ACCESS
	struct sigcontext_struct *context = the_context;
	void *pc_at_signal = (void *) context->PC_ACCESS;

	sprintf(buf, "PC at signal: %ld (%lx)\n",
		(long)pc_at_signal, (long)pc_at_signal);
  #else
	buf[0] = '\0';
  #endif

	return buf;
}

#elif defined(HAVE_SIGINFO_T)

void 
setup_signal(void)
{
	struct sigaction	act;

	act.sa_flags = SA_SIGINFO | SA_RESTART;
	if (sigemptyset(&act.sa_mask) != 0) {
		perror("Mercury runtime: cannot set clear signal mask");
		exit(1);
	}

	act.SIGACTION_FIELD = complex_bushandler;
	if (sigaction(SIGBUS, &act, NULL) != 0) {
		perror("Mercury runtime: cannot set SIGBUS handler");
		exit(1);
	}

	act.SIGACTION_FIELD = complex_segvhandler;
	if (sigaction(SIGSEGV, &act, NULL) != 0) {
		perror("Mercury runtime: cannot set SIGSEGV handler");
		exit(1);
	}
}

static void 
complex_bushandler(int sig, siginfo_t *info, void *context)
{
	fflush(stdout);

	if (sig != SIGBUS || !info || info->si_signo != SIGBUS) {
		fprintf(stderr, "\n*** Mercury runtime: ");
		fprintf(stderr, "caught strange bus error ***\n");
		exit(1);
	}

	fprintf(stderr, "\n*** Mercury runtime: ");
	fprintf(stderr, "caught bus error ***\n");

	if (info->si_code > 0) {
		fprintf(stderr, "cause: ");
		switch (info->si_code)
		{
		case BUS_ADRALN:
			fprintf(stderr, "invalid address alignment\n");
			break;

		case BUS_ADRERR:
			fprintf(stderr, "non-existent physical address\n");
			break;

		case BUS_OBJERR:
			fprintf(stderr, "object specific hardware error\n");
			break;

		default:
			fprintf(stderr, "unknown\n");
			break;

		} /* end switch */

		fprintf(stderr, "%s", explain_context(context));
		fprintf(stderr, "address involved: %p\n",
			(void *) info->si_addr);
	} /* end if */

	MR_trace_report(stderr);
	print_dump_stack();
	dump_prev_locations();
	fprintf(stderr, "exiting from signal handler\n");
	exit(1);
} /* end complex_bushandler() */

static void 
explain_segv(siginfo_t *info, void *context)
{
	fflush(stdout);

	fprintf(stderr, "\n*** Mercury runtime: ");
	fprintf(stderr, "caught segmentation violation ***\n");

	if (!info) {
		return;
	}

	if (info->si_code > 0) {
		fprintf(stderr, "cause: ");
		switch (info->si_code)
		{
		case SEGV_MAPERR:
			fprintf(stderr, "address not mapped to object\n");
			break;

		case SEGV_ACCERR:
			fprintf(stderr, "bad permissions for mapped object\n");
			break;

		default:
			fprintf(stderr, "unknown\n");
			break;
		}

		fprintf(stderr, "%s", explain_context(context));
		fprintf(stderr, "address involved: %p\n",
			(void *) info->si_addr);

	} /* end if */
} /* end explain_segv() */

static void 
complex_segvhandler(int sig, siginfo_t *info, void *context)
{
	if (sig != SIGSEGV || !info || info->si_signo != SIGSEGV) {
		fprintf(stderr, "\n*** Mercury runtime: ");
		fprintf(stderr, "caught strange segmentation violation ***\n");
		exit(1);
	}

	/*
	** If we're debugging, print the segv explanation messages
	** before we call try_munprotect.  But if we're not debugging,
	** only print them if try_munprotect fails.
	*/

	if (memdebug) {
		explain_segv(info, context);
	}

	if (try_munprotect(info->si_addr, context)) {
		if (memdebug) {
			fprintf(stderr, "returning from signal handler\n\n");
		}

		return;
	}

	if (!memdebug) {
		explain_segv(info, context);
	}

	MR_trace_report(stderr);
	print_dump_stack();
	dump_prev_locations();
	fprintf(stderr, "exiting from signal handler\n");
	exit(1);
} /* end complex_segvhandler */

static char *
explain_context(void *the_context)
{
	static	char	buf[100];

  #ifdef PC_ACCESS

	ucontext_t *context = the_context;

    #ifdef PC_ACCESS_GREG
	sprintf(buf, "PC at signal: %ld (%lx)\n",
		(long) context->uc_mcontext.gregs[PC_ACCESS],
		(long) context->uc_mcontext.gregs[PC_ACCESS]);
    #else
	sprintf(buf, "PC at signal: %ld (%lx)\n",
		(long) context->uc_mcontext.PC_ACCESS,
		(long) context->uc_mcontext.PC_ACCESS);
    #endif

  #else /* not PC_ACCESS */

	/* if PC_ACCESS is not set, we don't know the context */
	/* therefore we return an empty string to be printed  */
	buf[0] = '\0';

  #endif /* not PC_ACCESS */

	return buf;
}

#else /* not HAVE_SIGINFO_T && not HAVE_SIGCONTEXT_STRUCT */

void 
setup_signal(void)
{
	if (signal(SIGBUS, simple_sighandler) == SIG_ERR) {
		perror("cannot set SIGBUS handler");
		exit(1);
	}

	if (signal(SIGSEGV, simple_sighandler) == SIG_ERR) {
		perror("cannot set SIGSEGV handler");
		exit(1);
	}
}

static void 
simple_sighandler(int sig)
{
	fflush(stdout);
	fprintf(stderr, "*** Mercury runtime: ");

	switch (sig)
	{
	case SIGBUS:
		fprintf(stderr, "caught bus error ***\n");
		break;

	case SIGSEGV:
		fprintf(stderr, "caught segmentation violation ***\n");
		break;

	default:
		fprintf(stderr, "caught unknown signal %d ***\n", sig);
		break;
	}

	print_dump_stack();
	dump_prev_locations();
	fprintf(stderr, "exiting from signal handler\n");
	exit(1);
}

#endif /* not HAVE_SIGINFO_T && not HAVE_SIGCONTEXT_STRUCT */

#ifndef	MR_LOWLEVEL_DEBUG

static void 
print_dump_stack(void)
{
	const char *msg =
		"You can get a stack dump by using `--low-level-debug'\n";
	write(STDERR, msg, strlen(msg));
}

#else /* MR_LOWLEVEL_DEBUG */

static void 
print_dump_stack(void)
{
	int	i;
	int	start;
	int	count;
	char	buf[2560];

	strcpy(buf, "A dump of the det stack follows\n\n");
	write(STDERR, buf, strlen(buf));

	i = 0;
	while (i < dumpindex) {
		start = i;
		count = 1;
		i++;

		while (i < dumpindex &&
			strcmp(((char **)(dumpstack_zone->min))[i],
				((char **)(dumpstack_zone->min))[start]) == 0)
		{
			count++;
			i++;
		}

		if (count > 1) {
			sprintf(buf, "%s * %d\n",
				((char **)(dumpstack_zone->min))[start], count);
		} else {
			sprintf(buf, "%s\n",
				((char **)(dumpstack_zone->min))[start]);
		}

		write(STDERR, buf, strlen(buf));
	} /* end while */

	strcpy(buf, "\nend of stack dump\n");
	write(STDERR, buf, strlen(buf));

} /* end print_dump_stack() */

#endif /* MR_LOWLEVEL_DEBUG */

