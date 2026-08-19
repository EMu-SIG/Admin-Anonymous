#!/usr/bin/regina

/*

Grim Reaper for KE EMu 9.1+ under Solaris

Larry Gall
Yale Peabody Museum
lawrence.gall@yale.edu

First version: Dec 2005
Last modified: Aug 2024

- - - - -

The Reaper sniffs out both idle and runaway texserver processes, and
kills them off as needed, based on various criteria.  It is designed
to be run via cron frequently.  When it wakes up, the Reaper takes
a snapshot of the current texlicstatus output and a snapshot of the
current ps output from running texservers, compares the data to the
prior available snapshot, and then decides the fate of each running
texserver.  The snapshot is organized as four strings (nominees,
nomineepids, nomineeflags, nomineetimes) which contain blank delimited
lists of usernames, process ids, kill flags, and CPU times, respectively.
A texserver is testable for killing at the {flaglimit} interval.  If after
that time the cumulative CPU time has not changed since the first interval,
the texserver is killed.  If the CPU time has changed, the texserver is
left alone, unless the CPU delta exceeds {maxdelta} seconds in which case the
texserver is deemed possibly rogue and a message is printed.  Thus, the 
combination of {maxdelta}, {flaglimit}, and cron periodicity can be used to tune 
the sensitivity of the Reaper.  A list of users who are exempt from killing 
is held in {sacredusers}.  For production use, set {debug} to 0 and
{reaping} to 1, which will make the Reaper run silentely and do its thing.
Setting {debug} to 1 prints processing statistics and {reaping} to 0
disables any attempt to actually kill a process - these are good settings
to let you observe how the Reaper would behave in your environment, which 
is a prudent plan before you actually turn it loose.

Data need to be accumulated from both ps and texlicstatus output in
order to make an informed decision about process killability on a
Solaris system running EMu.  Hence, a number of the tests below rely
on repeated looping across either the texlicstatus output or the
ps output.  There is likely a more efficient way to code this, but
the present incarnation seems reasonably concise.  At present, the
code for determining what constitutes a runaway process has also been
commented out (because empirically at Peabody we do not observe them). 

- - - - -

The Reaper is a Rexx script.  To run the Reaper, install the free
Regina Rexx interpreter from http://regina-rexx.sourceforge.net/index.html
Currently a precompiled (v3.9.1) Solaris 11 binary is there, all you need to do
is unzip the distribution and move the resulting directory to a good location,
and append its {bin} and {lib} onto the PATH and LD_LIBRARY_PATH variables.
An experienced scripter should be able to convert the Rexx script to
Perl or another language, if desired. At Peabody, the Regina distribution
is untarred into /usr/bin. The Reaper script is called via a
generic wrapper shell script that guarantees a suitable EMu/texpress
environment.  It is run from the emu crontab as follows, for example:

   #  Grim Reaper
   0,10,20,30,40,50 7-19 * * * emu-wrapper emureaper
   #

*/

/* Establish values for primary control variables */

trace off

reaping        = 1         /* 1 to reap, anything else does no reaping         */
debug          = 0         /* 1 to show various debugging stats, 0 for not     */
looplimit      = 1         /* a vestige from earlier version... do not modify  */
flaglimit      = 4         /* number of testing intervals you may stay idle    */
sacreds        = 2         /* set this to the number of sacredusers            */
specials       = 2         /* set this to the number of specialusers           */
maxdelta       = 500       /* rogue CPU time est. for typical test interval    */
maxlicenses    = 23        /* set this to the number of EMu server licenses    */ 
sacredusers    = 'emu lfg'             /* EMu users that should be ignored by the Reaper  */
specialusers   = 'ealw gjm'            /* EMu users that should be given twice the time   */

speciallimit   = 2 * flaglimit

/* Notes on rogues... any on the Yale Solaris servers seem to zombie with      */
/* a delta of about 15 per minute.  Thus, we consider someone suspect if the   */
/* maxdelta is around 500 which would likely be seen within 30 minutes and     */
/* is not likely to inadvertantly flag someone doing a large import            */

/* Full pathnames and locations of essential Unix commands */

cmd_texs  = '/export/home/emu/texpress/11.0/bin/texlicstatus | /usr/bin/egrep -v pts'
cmd_kill  = '/usr/bin/kill -9'
cmd_null  = '/usr/bin/cp /dev/null'
cmd_date  = "/usr/bin/date '+%H'"
cmd_pids  = '/usr/bin/ps -ef | /usr/bin/egrep texserver | /usr/bin/egrep -v pts | /usr/bin/egrep -v egrep | cut -c1-25,40-100'
cmd_touch = '/usr/bin/touch'

/* Full pathnames to the control and logfiles, with reapfile  */
/* being the continuously updated table of texserver data,    */
/* reaplog being the file showing who was killed, and statlog */
/* being a file to record who is logged on at each interval   */

reapfile  = '/var/tmp/emureaper.tmpfile'
reaplog   = '/export/home/emu/ypmnh/server/local/logs/emureaper.log'
statlog   = '/export/home/emu/ypmnh/server/local/logs/emustatus.log'

/* Default the four primary string variables */

nominees = ''
nomineepids = ''
nomineeflags = ''
nomineetimes = ''

/* Default the texlicstatus output lines that are observable */

do x = 1 to maxlicenses
   texlicstatuslines.x = ''
   end

/* Get any existing data from the control file */

this = cmd_touch reapfile
this = POPEN(this)
do x = 1 TO 4
   IF ( LINES(reapfile) = 0 ) THEN LEAVE x
   this = LINEIN(reapfile)
   this = STRIP(this)
   IF ( x = 1 ) THEN nominees = this
   IF ( x = 2 ) THEN nomineepids = this
   IF ( x = 3 ) THEN nomineeflags = this
   IF ( x = 4 ) THEN nomineetimes = this
   END
CALL LINEOUT reapfile

/* Top of primary loop */

DO x = 1 to looplimit
 
   /* Print a header if debugging */

   IF ( debug = 1 ) THEN DO
      SAY ''
      SAY 'Iteration number =' x 'at' date() time()
      END
   
   /* OK, good to go.  Run texlicstatus to get current list of all logged in  */
   /* users and place it on the stack.  Note that the format of this command  */
   /* changed from 9.0 to 9.1   It used to be that the first six lines of the */
   /* texlicstatus output are site specific data that we do not want.  The    */
   /* seventh and subsequent lines contained one-liners for logged in users.  */
   /* As of 9.1, the output shows not only the server data, but also data for */
   /* other services such as restapi, go, etc. and the output is much longer. */ 
   /* Since the internal Regina stack is LIFO, user data are at the top of    */
   /* the stack (if present), so we could skim these and ignore other lines.  */
   /* Since the server texlicstatus output is the last data displayed, we     */ 
   /* accumlate lines until we encounter "Licence: server" and then process.  */
   /*                                                                         */
   /* Within a line of interest, the sixth token is the username and          */
   /* the seventh is the process id... toast the stack when finished.         */

   this = POPEN(cmd_texs)

   lines = QUEUED()
   wanted = 0
   DO y = 1 to lines
      PARSE PULL this
      this = STRIP(SPACE(this))
      that = STRIP(word(this,1)) 
      if ( that = ''         ) then leave y
      if ( that = 'Licence:' ) then leave y
      if ( that = 'Current'  ) then leave y
      if ( that = 'Maximum'  ) then leave y
      wanted = wanted + 1
      texlicstatuslines.wanted = this
      END
   this = DROPBUF(0)

   /* Bail out if nobody home */
   IF ( wanted < 1 ) THEN DO
      IF ( debug = 1 ) THEN SAY 'nobody logged on' date() time()
      this = cmd_null reapfile
      this = POPEN(this)
      EXIT 
      END

   that = ''
   nservers = 0
   DO y = 1 to wanted
      nservers = nservers + 1
      PARSE VALUE texlicstatuslines.y with . . . . . username.nservers serverpid.nservers .
      serverpid.nservers = STRIP(serverpid.nservers)
      username.nservers = STRIP(username.nservers)
      if ( username.nservers \= 'emu' ) THEN that = that username.nservers
      END
   this = DROPBUF(0)

   /* Write a line indicating how many are logged on */
   IF ( that \= '' ) THEN DO
      this = right(words(that),2) 'users at' date() time() that
      this = '/usr/bin/echo' this '>>' statlog
      this = POPEN(this)
      END

   /* Now accumulate the process id and total CPU usage  */
   /* for every currently running texserver process. In  */
   /* a Solaris ps output the process id is token two,   */
   /* and the total cpu is token seven if the job is     */
   /* fairly recent but token eight if quite old, which  */
   /* is why we use cut in cmd_pids, result token five   */

   this = POPEN(cmd_pids)
   running = QUEUED()
   DO y = 1 TO running
      PARSE PULL this
      PARSE VALUE this WITH . pid.y . . . . totalcpu.y .
      PARSE VALUE this WITH . pid.y . . totalcpu.y .
      PARSE VALUE totalcpu.y WITH mins ':' secs
      pid.y = STRIP(pid.y)
      mins = STRIP(mins)
      mins = STRIP(mins,'L','0')
      secs = STRIP(secs)
      secs = STRIP(secs,'L','0')
      if ( mins = '' ) then mins = 0
      if ( secs = '' ) then secs = 0
      totalcpu.y = ( mins * 60 ) + secs
      END

   /* Default the main variables for this test interval: {kills}  */
   /* has pids to be killed, {ignores} has pids to be skipped,    */
   /* {newminee} vars will be used to refresh the prior ones.     */

   kills = ''
   killees = ''
   ignores = ''

   newminees = ''
   newmineepids = ''
   newmineetimes = ''
   newmineeflags = ''
     
   /* Here we are at the start of the main analysis subloop.  We take  */
   /* a look at every entry in the existing nominee arrays and make a  */
   /* decision as to the fate of each texserver based on our criteria. */

   n = WORDS(nominees)

   DO y = 1 TO n
      myname = WORD(nominees,y)
      myflag = WORD(nomineeflags,y)
      mytime = WORD(nomineetimes,y)
      mypid  = WORD(nomineepids,y)
      
      /* Check to see if I am still in the current texlicstatus output */

      result = 0
      DO z = 1 TO nservers
         IF mypid = serverpid.z THEN result = 1
         END

      /* I am no longer there, so I must have logged out */

      IF ( result = 0 ) THEN DO   
         ignores = ignores mypid
         ITERATE y
         END

      /* I am still there, see if I can be killed */

      IF ( result = 1 ) THEN DO   
         myflag = myflag + 1

         /* If sacred, effectively ignore me by always resetting flaglimit to 1 */

         DO z = 1 TO sacreds
            sacred = WORD(sacredusers,z)
            IF ( myname = sacred ) THEN DO
	       IF ( debug = 1 ) THEN SAY '  skipping sacred user:' myname
               newminees = newminees myname
               newmineepids = newmineepids mypid
               newmineeflags = newmineeflags '1'
               newmineetimes = newmineetimes mytime
               ignores = ignores mypid
               ITERATE y
               END
            END

         /* Set the flagtest interval; it is triple for specialusers */

         flagtest = flaglimit
         DO z = 1 TO specials
            special = WORD(specialusers,z)
            IF ( myname = special ) THEN DO
	       IF ( debug = 1 ) THEN SAY '  testing special user:' myname
               flagtest = speciallimit 
               END
            END

         /* Keep me alive if I have not yet passed the flagtest */

         IF ( myflag <= flagtest ) THEN DO        
            newminees = newminees myname
            newmineepids = newmineepids mypid
            newmineeflags = newmineeflags myflag
            newmineetimes = newmineetimes mytime
            ignores = ignores mypid
            ITERATE y
            END

         /* OK, I am over the flagtest, check my CPU deltas... */

         IF ( myflag > flagtest ) THEN DO      
            DO z = 1 to running
               this = pid.z
               delta = totalcpu.z - mytime
               IF ( this = mypid ) THEN DO

		  IF ( debug = 1 ) THEN SAY '  testing delta of' delta 'for' mypid

                  /* My delta is zero, I have been idling, so croak me */

                  IF ( delta = 0 ) THEN DO
                     kills = kills mypid
		     killees = killees myname
                     ignores = ignores mypid
                     END

                  /* My delta is nonzero, do I seem like a rogue or not?  */

                  rogueflag = 0
		  IF ( delta >= maxdelta ) THEN rogueflag = 1
		  IF ( totalcpu.z >= maxdelta ) THEN rogueflag = 1
                  IF ( rogueflag = 1 ) THEN DO  
		     SAY ' '
		     SAY 'POSSIBLE ROGUE TEXSERVER =' mypid
		     SAY ' '
		     'ps -ef | grep' mypid '| grep aemu | grep -v grep'
		     SAY ' '
		     cmd_texs
                     END

                  END 
               END 
            END 
          END 
       END 
    
   /* Loop again over the current texlicstatus entries to see if there are  */
   /* any that represent new logins since the last time interval.  If so,   */
   /* append these onto the growing list of new nominees.                   */
  
   DO y = 1 TO nservers
      myname = username.y
      mypid = serverpid.y
      result = 0

      /* Skip me if I am already in the ignores and hence accounted for */

      m = WORDS(ignores)
      DO z = 1 TO m
         that = WORD(ignores,z)
         IF ( mypid = that ) THEN result = 1
         END

      /* If not already ignored, I need to be added to the list */

      IF ( result = 0 ) THEN DO
         that = 0
         DO w = 1 TO running
            IF ( mypid = pid.w ) THEN that = totalcpu.w
            END
         newminees = newminees myname
         newmineepids = newmineepids mypid
         newmineeflags = newmineeflags '1'
         newmineetimes = newmineetimes that
         ignores = ignores mypid
         END

      END

   /* OK, we are ready.  First strip the nominee and newminee  */
   /* variables just for compulsiveness sake, and if we are    */ 
   /* debugging write summary statistics to stdout...          */

   nominees = STRIP(nominees)
   nomineepids = STRIP(nomineepids)
   nomineetimes = STRIP(nomineetimes)
   nomineeflags = STRIP(nomineeflags)

   newminees = STRIP(newminees)
   newmineepids = STRIP(newmineepids)
   newmineetimes = STRIP(newmineetimes)
   newmineeflags = STRIP(newmineeflags)

   IF ( debug = 1 ) THEN DO
      SAY 'Prior nominee list:'
      n = WORDS(nominees)
      DO y = 1 TO n
         SAY ' ' WORD(nominees,y) WORD(nomineepids,y) WORD(nomineeflags,y) WORD(nomineetimes,y)
         END
      SAY 'Current nominee list:'
      n = WORDS(newminees)
      DO y = 1 TO n
         SAY ' ' WORD(newminees,y) WORD(newmineepids,y) WORD(newmineeflags,y) WORD(newmineetimes,y)
         END
      SAY 'Flagged as ignores:' ignores
      SAY 'Flagged as kills:' kills
      END
   
   /* ... OK, it is time to blast the idling EMu users silly!   */
   /* [Captain]: What's that sound?  [Engineer]: I think it's   */
   /* Morse Code.  [tap tap tap]  [Captain]: What does it say?  */
   /* [dramatic pause]  [Engineer]: "I am U-571, destroy me!"   */

   n = WORDS(kills)
   DO y = 1 TO n
      this = WORD(kills,y)
      that = WORD(killees,y)
      IF ( reaping \= 1 ) THEN DO
         SAY 'Would be reaping' that this 'at' time() date()
         END
      IF ( reaping = 1 ) THEN DO
	 they = cmd_touch reaplog
	 they = POPEN(they)
	 they = 'reaping' that this 'at' time() date()
	 call lineout reaplog,they
	 call lineout reaplog
	 IF ( debug = 1 ) THEN SAY '--> Reaping' that this 'at' time() date()
         this = cmd_kill this
         this = POPEN(this)
         END
      END

   /* Refresh the master nominee list and reaper control file... */

   nominees = newminees
   nomineepids = newmineepids
   nomineetimes = newmineetimes
   nomineeflags = newmineeflags

   this = cmd_null reapfile
   this = POPEN(this)
   CALL LINEOUT reapfile,nominees 
   CALL LINEOUT reapfile,nomineepids 
   CALL LINEOUT reapfile,nomineeflags 
   CALL LINEOUT reapfile,nomineetimes 
   CALL LINEOUT reapfile
   
   END

EXIT    

