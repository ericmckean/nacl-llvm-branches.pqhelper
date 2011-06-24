#!/usr/bin/perl -w
# -w
# -*- perl -*-


package RepoHelper;
use strict;
use warnings;
use File::Basename;
use File::Temp qw/ tempfile tempdir /; ;
#use IPC::System::Simple;
#use autodie qw(:all);

BEGIN {
  use Exporter   ();
  our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

  # set the version for version checking
  $VERSION     = 1.00;
  # if using RCS/CVS, this may be preferred
  $VERSION = sprintf "%d.%03d", q$Revision: 1.1 $ =~ /(\d+)/g;

  @ISA         = qw(Exporter);
  @EXPORT      = qw(&GetRepoRoot &QuoteIt &Shell &Piped &GetHgLog 
                    &SaveTestArtifacts &WriteLog 
                    &MergePatchHeader &GetRevName
                    &TagRepo 
                    &Merge3 &MergeOneFile &MergeOneFileAlt
                    &HgPushLoop &HgGetUnknownFiles
                    &HgCommitMqRefresh &SubChunkHasNonBlankDelta
                    &ProcessPatch &StripWhiteSpace &StripAllWhiteSpace
                    &AdjustSubchunkHeader &AdjustAllSubchunkHeaders
                    &ArgvHasFlag &ArgvHasOpt &ArgvHasUniqueOpt);
  %EXPORT_TAGS = ( );           # eg: TAG => [ qw!name1 name2! ],

  # your exported package globals go here,
  # as well as any optionally exported functions
  @EXPORT_OK   = @EXPORT;
}
our @EXPORT_OK;
END { }       # module clean-up code here (global destructor)

sub TagRepo {
  my ($RepoRoot, $BaseRev, $Tag, $ans) = @_;
  my ($Orig); chomp($Orig = `pwd`);
  chomp($RepoRoot = `pwd`) if ($RepoRoot eq '');
  chdir $RepoRoot;
  print "Tag the repo with $Tag ? ";
  $ans = <STDIN> if ($ans eq '');
  if ($ans =~ /y(e(s)?)?/i) {
    Shell("hg qpop -a");
    my (%Log) = &GetHgLog($BaseRev);
    my ($RevName) = &GetRevName(%Log);
    Shell("hg tag -l -r $Log{rev} ${RevName}${Tag}");
  }
  chdir $Orig;
}

sub HgPushLoop() {
  my (@PatchList) = @_;
  my ($MqPatch);
  my (@Files) = &HgGetUnknownFiles();
  if ($#Files >= 0) {
    print  "\t" . join("\t\n", @Files) .
      "\n*WARNING! he above untracked files are in the repo.\n" .
        "Please either PQHelper.pl -Clean or merge them somehow\n";
  }

  foreach $MqPatch (@PatchList) {
    last if ($MqPatch eq "STOP");
    chomp $MqPatch;
    print "Processing $MqPatch\n";
    Shell("hg qpush $MqPatch", "", "");
  }
  Shell("hg -R .hg/patches stat", "");
}

sub HgGetUnknownFiles() {
  my (@Files) = map { chomp; $_ = substr($_,2) } 
    grep { /^?/ } 
      Piped("hg stat -u", "Getting unknown files..");
  return @Files;
}

sub MergeOneFile {
  my ($RepoDir, $BaseRevLog, $CurrRevLog, $Target, $TmpDir) = @_;
  my ($File, $Dir) = &fileparse($Target);
  my ($Orig); chomp($Orig = `pwd`);
  chdir $RepoDir;
  print "Refresh/Rebase Merge, working dir $TmpDir for file $Target\n";
  print "FromMqRev:\n";
  &WriteLog($BaseRevLog);
  print "ToRev:\n";
  &WriteLog($CurrRevLog);

  my ($BaseRevName) = &GetRevName(%$BaseRevLog);
  my ($CurrRevName) =  &GetRevName(%$CurrRevLog);

  die "File ${RepoDir}/${Target}  does not correspond to an existing file in the repo\n"
    if (! -e "${RepoDir}/${Target}");

  my @MqStatus = grep { chomp } Piped("hg -R .hg/patches stat -n", "get mqrepo status");

  Shell("mkdir -p ${TmpDir}/${Dir}", "mimic the src directory");
  Shell("hg cat -r ${$BaseRevLog}{rev} ${Target} -o ${TmpDir}/${Target}.${BaseRevName}",
        "Get version $BaseRevName of  ${Target}");
  Shell("cp ${TmpDir}/${Target}.$BaseRevName ${TmpDir}/${Target}",
        "Copy before patching");

  my (@MqApplied) = grep { chomp } Piped("hg qapplied", "get applied patch sequence");
  my (@MqOrig);
  my ($Patch);
  foreach $Patch (@MqApplied) {
    Shell("hg cat -R .hg/patches -r $BaseRevName .hg/patches/$Patch -o ${TmpDir}/${Dir}${Patch}.${BaseRevName}",
          "Get version $BaseRevName of $Patch");
    push @MqOrig, "${TmpDir}/${Dir}${Patch}.${BaseRevName}";
  }
  my (@Chunks);
  foreach $Patch (@MqOrig) {
    my (@Chunk) = &HgGrabChangesTo($Patch, $Target);
    push (@Chunks, @Chunk) if ($#Chunk >= 2);
  }
  # generate two sets of 
  if ($#Chunks >= 0) {
    open (my $Fh, ">${TmpDir}/${Target}.${BaseRevName}.patch")
      || die "Unable to create a prior patch for ${TmpDir}/${Target}\n";
    print $Fh @Chunks;
    close $Fh;
    &ApplyPatch("${TmpDir}/${Target}.${BaseRevName}.patch", $Target, $TmpDir, "-p1");
  }
  Shell("kdiff3 ${TmpDir}/${Target}.${BaseRevName} ${TmpDir}/${Target} ${Target}",
        "run the merge3");
  chdir $Orig;
}

sub MergeOneFileAlt {
  my ($RepoDir, $BaseRevLog, $CurrRevLog, $Target, $TmpDir) = @_;
  my ($File, $Dir) = &fileparse($Target);
  my ($Orig); chomp($Orig = `pwd`);
  chdir $RepoDir;
  print "Refresh/Rebase Merge, working dir $TmpDir for file $Target\n";
  print "FromMqRev:\n";
  &WriteLog($BaseRevLog);
  print "ToRev:\n";
  &WriteLog($CurrRevLog);

  my ($BaseRevName) = &GetRevName(%$BaseRevLog);
  my ($CurrRevName) =  &GetRevName(%$CurrRevLog);

  die "File ${RepoDir}/${Target}  does not correspond to an existing file in the repo\n"
    if (! -e "${RepoDir}/${Target}");

  Shell("mkdir -p ${TmpDir}/${Dir}", "mimic the src directory");
  Shell("hg cat -r ${$BaseRevLog}{rev} ${Target} -o ${TmpDir}/${Target}.${BaseRevName}",
        "Get version $BaseRevName of  ${Target}");

  my (@MqApplied) = grep { chomp } Piped("hg qapplied", "get applied patch sequence");
  my (@MqOrig);
  my ($Patch, $i);
  foreach $Patch (@MqApplied) {
    Shell("hg cat -R .hg/patches -r $BaseRevName .hg/patches/$Patch -o ${TmpDir}/${Dir}${Patch}.${BaseRevName}",
          "Get version $BaseRevName of $Patch");
    push @MqOrig, "${TmpDir}/${Dir}${Patch}.${BaseRevName}";
  }
  my (@PatchesToTarget);
  foreach $Patch (@MqOrig) {
    my (@Chunk) = &HgGrabChangesTo($Patch, $Target);
    push (@PatchesToTarget, \@Chunk); # if ($#Chunk >= 2);
  }
  # generate two sets of merged files
  #
  my (@PatchSeq) = &GenTwoPatches($TmpDir, $Target, $BaseRevName, 
                                  $CurrRevName,
                                  \@PatchesToTarget, \@MqApplied);
  foreach $i (0 .. $#PatchSeq) {
    if (-r $PatchSeq[$i]) {
      $Patch = $PatchSeq[$i];
      Shell("cp ${TmpDir}/${Target}.$BaseRevName ${TmpDir}/${Target}",
            "Copy before patching (pass $i)");

      &ApplyPatch($Patch, "${Target}.${i}", $TmpDir, "-p1");
      Shell("cp ${TmpDir}/$Target ${TmpDir}/${Target}.${BaseRevName}.${i}",
            "save the results ");
    } else {
      Shell("cp ${TmpDir}/$Target.${BaseRevName} ${TmpDir}/${Target}.${BaseRevName}.${i}",
            "No patch, so copy instead (pass $i)");
    }
  }
  Shell("kdiff3 ${TmpDir}/${Target}.${BaseRevName}.0 ${TmpDir}/${Target}.${BaseRevName}.1 ${Target}",
        "run the merge3");
  my ($x);
  print "kdiff3 finished. Here is the repo status\n";
  Shell("hg stat", "see the mods");

  print "Continue to see the mq status? "; $x = <STDIN>;
  Shell("hg qstat", "see the change to the queue");

  print "Continue to see current diff? "; $x = <STDIN>;
  Shell("hg diff", "see the diff before refresh");
  print "Continue? "; $x = <STDIN>;
  print "If you are done with this patch, don't forget to the following\n";
  print "  hg qrefresh\n";
  print "  $::PROGRAM_NAME -CommitRefresh\n";
  chdir $Orig;
}

# Routine takes an array of of specific patches against $Target
# It generates two patches against target. The SECOND one contains
# all diff chunks. The FIRST one contains all but the last chunk.
# this is hopefully to show in merge3 the difference between patch set 
# N-1 and N
sub GenTwoPatches {
  my ($TmpDir, $Target, $BaseRevName, $CurrRevName, $PatchesToTargetOrig, $PatchNames) = @_;
  my @Rtn;
  my $_;
  die "Total of ${\($#{$PatchesToTargetOrig}+1)} diffs against $Target but ${\($#{$PatchNames}+1)} patches!\n"
    if ($#{$PatchesToTargetOrig} != $#{$PatchNames});
  my (@PatchIdx) = 0; my($i) =0;
  my (@PatchesToTarget) = grep {
    print "Patch $i (from ${$PatchNames}[$i])\n";
    print @{$_};
    if ($#{$_} > -1) {
      print "Grabbed a diffchunk against $Target from @{$PatchNames}[$i] [$i]\n";
      push @PatchIdx, $i;
      $i++;
      1;
    } else {
      $i++;
      0;
    }
  } @{$PatchesToTargetOrig};

  die "There are no diffs against $Target in the following:\n" .
    join("\n\t", @{$PatchNames}) . "\n" if ($#PatchesToTarget == -1);
  print "There are ${\($#PatchesToTarget+1)} diffchunks for $Target from ${\($#{$PatchNames}+1)} patches\n";
  die "Not enough patches to $Target!\n" if ($#PatchesToTarget == -1);
  
  # It's a lie. There can only be two.
  # 
  my ($x) = $#PatchesToTarget -1;
  my ($j) = 0; $i = 0;
  while ($x <= $#PatchesToTarget) {
    my $PatchName = "${TmpDir}/${Target}.${BaseRevName}.${j}.patch";
    if ($x < 0) {
      print "Since there is only ${\($#PatchesToTarget+1)} patche to $Target. The first one is empty\n";
      push @Rtn, '';
      next;
    } else {
       push @Rtn, $PatchName;
    }
    Shell("rm -f ${PatchName}", "clear before creating new patch");
    print "PatchName = $PatchName\n";
    for $i (0 .. ($x)) {
      my ($PatchRef) = $PatchesToTarget[$i];
      my $Line;
      print "Grabbing patch to $Target from ${$PatchNames}[$PatchIdx[$i]], saving it to $PatchName\n";
      open (my $Fh, ">>$PatchName")
        || die "Unable to create a prior patch for ${TmpDir}/${Target} (from ${$PatchNames}[$PatchIdx[$i]], seq $j)\n";
      for $Line (@{$PatchRef}) {
        print $Fh $Line;
      }
      close $Fh;
    }
  } continue { $x++; $j++; };
  return @Rtn;
}

sub Merge3 {
  my ($RepoDir, $BaseRev, $CurrRev, @Rejected) = @_;
  chomp($RepoDir=`pwd`) if ($RepoDir eq '');
  chdir $RepoDir;

  my (%BaseRevLog) = &GetHgLog($BaseRev);
  my (%CurrRevLog) = &GetHgLog($CurrRev);
  my ($BaseRevName) = &GetRevName(%BaseRevLog);
  my ($CurrRevName) = &GetRevName(%CurrRevLog);

  my ($TmpDir); chomp ($TmpDir = &tempdir("/tmp/hgmergeall.$BaseRevName.$CurrRevName.XXXXXX", CLEANUP => 0));
  &Merge3Loop($RepoDir, \%BaseRevLog, \%CurrRevLog, $TmpDir, @Rejected);
}

sub Merge3Loop {
  my ($RepoDir, $BaseRevLog, $CurrRevLog, $TmpDir, @Rejected) = @_;
  my ($Rej);
  my (@suffixes) = (qw(.rej -rej .orig -orig));
  print "Refresh/Rebase Merge, working dir $TmpDir\n";
  print "FromRev:\n";
  &WriteLog($BaseRevLog);
  print "ToRev:\n";
  &WriteLog($CurrRevLog);
  my ($x);
  my ($BaseRevName) = &GetRevName(%$BaseRevLog);
  my ($CurrRevName) =  &GetRevName(%$CurrRevLog);
  die "Require -OrigRev=REV (Curr Rev='$CurrRevName'\n"
    if ($BaseRevName eq $CurrRevName);
  foreach $Rej (@Rejected) {
    my ($File, $Dir, $Suffix) = &fileparse($Rej, @suffixes);
    # A: The $File @ $OrigRev
    # B: apply the .rej  to it
    # C: The current file (which should be at revision $CurrRev)
    my $Target="${Dir}${File}";
    if (! -e "${RepoDir}/${Dir}$File") {
      die "File $Rej does not correspond to an existing file in the repo. Please fix manually\n";
    } else {
      print "THIS IS A .REJ FILE. TWO EDITOR WINDOWS OPENING\n";
      Shell("$ENV{EDITOR} ${TmpDir}/${Dir}${File}${Suffix}&", "Start edit of ${TmpDir}/${Dir}${File}${Suffix}");
      Shell("mkdir -p ${TmpDir}/${Dir}", "mimic the src directory");
      Shell("mv $Rej ${TmpDir}/${Dir}", "Move reject hunk to Output directory");
      &MergeOneFileAlt($RepoDir, $BaseRevLog, $CurrRevLog, $Target, $TmpDir);
    }

    if (0) {
      print "MERGE3 STEP*******************\n";
      print "If the next step fails, you have no choice but to manually merge3 the following:\n";
      print "kdiff3 ${TmpDir}/${File}.$BaseRevName ${TmpDir}/${Dir}${File}${Suffix} ${Dir}/${File}\n";
      print "MERGE3 STEP*******************\n";
      Shell("mkdir -p ${TmpDir}/${Dir}", "mimic the src directory");
      Shell("mv $Rej ${TmpDir}/${Dir}", "Move reject hunk to Output directory");

      Shell("hg cat -r ${$BaseRevLog}{rev} ${Dir}$File -o ${TmpDir}/${Dir}${File}.$BaseRevName",
            "Get version $BaseRevName of  ${Dir}$File");
      if ($BaseRevName ne $CurrRevName) {
        print "Merging from $BaseRevName to $CurrRevName\n";
        Shell("cp ${TmpDir}/${Dir}${File}.$BaseRevName ${TmpDir}/${Dir}${File}",
              "Copy before patching");
        &ApplyAllPriorChanges("${Dir}$File", $TmpDir, $Dir, $Rej, $BaseRevName);
        Shell("kdiff3 ${TmpDir}/${Dir}${File}.$BaseRevName ${TmpDir}/${Dir}${File} ${Dir}${File}");
      } else {
        print "Merging current patch for 1 revision $BaseRevName.\n";
        print "MERGE3 STEP*******************\n";
        print "THIS IS A TWO WAY MERGE. TWO EDITOR WINDOWS OPENING\n";
        Shell("$ENV{EDITOR} ${TmpDir}/${Dir}${File}${Suffix}&", "Start edit of ${TmpDir}/${Dir}${File}${Suffix}");
        Shell("kdiff3 ${TmpDir}/${Dir}${File}.$BaseRevName ${Dir}/${File}", "suboptimal 2way merge");
        print "MERGE3 STEP*******************\n";
      }
    }
  }
  print "About to see entire change... Continue? "; $x = <STDIN>;
  Shell("hg qdiff", "Entire change");
  print "Continue? "; $x = <STDIN>;

  Shell("hg qrefresh", "refresh the patch");
  &HgCommitMqRefresh($RepoDir, ${$CurrRevLog}{rev});

}

sub ApplyAllPriorChanges {
  my ($SrcFile, $TmpDir, $Dir, $Rej, $BaseRevName) = @_;
  # cherrypick all 
  my ($PatchFile, @Chunks);
  my (@MqApplied) = grep { chomp } Piped("hg qapplied", "grab all changes to $SrcFile");
  foreach $PatchFile (@MqApplied) {
    my (@Chunk) = &HgGrabChangesTo(".hg/patches/$PatchFile", $SrcFile);
    push (@Chunks, @Chunk) if ($#Chunk >= 2);
  }
  print "Now applying the rejected chunk *************************\n";
  Shell("cat ${TmpDir}/${Rej}", "The rejected chunk");
  my ($x) = <STDIN>;
  if ($#Chunks >= 0) {
    open (my $Fh, ">${TmpDir}/${SrcFile}.prior.patch")
      || die "Unable to create a prior patch for ${SrcFile}\n";
    print $Fh @Chunks;
    close $Fh;
    &ApplyPatch("${TmpDir}/${SrcFile}.prior.patch", $SrcFile, $TmpDir, "-p1");
  } else {
    Shell("(cd ${TmpDir}/${Dir}; patch -p0 < ${TmpDir}/${Rej})",
        "apply the rejected hunk");
  }
}

sub ApplyPatch {
  my ($PatchFile, $TargetFile, $WDir, $PatchArg) = @_;
  $PatchArg = "-p1" if ($PatchArg eq '');
  print "Applying the following diff against ${TargetFile} **********************\n";
  Shell("cat $PatchFile", "The prior patch");
  Shell("(cd $WDir; patch ${PatchArg} < $PatchFile)", "apply the patch");
}

sub HgGrabChangesTo {
  my ($PatchFile, $SrcFile) = @_;
  open (my $Fh, $PatchFile) || die "Unable to open patch '$PatchFile' for reading\n";
  my (@Lines) = <$Fh>;
  close $Fh;
  return &ProcessPatch(\ &HgGrabDiffAgainst, $SrcFile, @Lines);
}

sub HgGrabDiffAgainst {
  my ($SrcFile, @Chunk) = (@_);
  ($#Chunk >= 2) || die "@Chunk is incomplete";
  #print "Found Chunk $Chunk[0]";
  if ($Chunk[0] =~ /^diff.*\b${SrcFile}\b/x) {
    print "Found Chunk $Chunk[0]";
    return @Chunk;
  }
  return ();
}


sub ProcessPatch () {
  # @Chunk (for --unified diffs) has:
  # comments
  # diff ...
  # --- ...
  # +++ ...
  # followed by one or more SubChunk
  # @@ ...

  my ($Func, $Arg, @Lines) = (@_);
  my $Line;
  my $DiffStart = '';
  my @Chunk;
  my (@Rtn);

  foreach $Line (@Lines) {
    if ($Line =~ /^diff /) {
      $DiffStart = $Line;
      push @Rtn, &$Func($Arg, @Chunk) if ($#Chunk > 0 && $Chunk[0]=~ /^diff /);
      # clear Chunk out for next bit
      @Chunk = ();
    }
    push @Chunk, $Line;
  }
  push @Rtn, &$Func($Arg, @Chunk) if ($#Chunk >= 2);
  return @Rtn;
}


sub StripWhiteSpace {
  my ($FH, @Chunk) = (@_);
  my (@SubChunk);
  my (@DstChunk, $Line);
  ($#Chunk >= 2) || die "@Chunk is incomplete";
  push @DstChunk, shift @Chunk;
  push @DstChunk, shift @Chunk;
  push @DstChunk, shift @Chunk;

  foreach $Line (@Chunk) {
    if ($Line =~ /^@@ /) {
      if (($#SubChunk > 0) && &SubChunkHasNonBlankDelta(1, @SubChunk)) {
        push @DstChunk, @SubChunk;
      }
      @SubChunk = ();
    }
    push @SubChunk, $Line;
  }
  if ( ($#SubChunk > 0) && &SubChunkHasNonBlankDelta(1, @SubChunk)) {
    push @DstChunk, @SubChunk;
  }
  print $FH @DstChunk if ($#DstChunk > 2 && $FH ne '');
  return @DstChunk;
}

sub StripAllWhiteSpace() {
  my ($File, @Chunk) = (@_);
  my (@SubChunk);
  my (@DstChunk, $Line);

  ($#Chunk >= 2) || die "@Chunk is incomplete";
  push @DstChunk, shift @Chunk;
  push @DstChunk, shift @Chunk;
  push @DstChunk, shift @Chunk;
  my ($DiffLevel) = 1;

  foreach $Line (@Chunk) {
    if ($Line =~ /^@@ /) {
      if ($#SubChunk > 2)  {
        push @DstChunk, &StripWhiteSpaceChangesInSubChunk($DiffLevel, @SubChunk);
      }
      @SubChunk = ();
    }
    push @SubChunk, $Line;
  }
  if ($#SubChunk > 2)  {
    push @DstChunk,  &StripWhiteSpaceChangesInSubChunk($DiffLevel, @SubChunk);
  }

  print $File @DstChunk if ($#DstChunk > 2 && $File ne '') ;

  return @DstChunk;
};

sub SubChunkHasNonBlankDelta() {
  my ($DiffLevel, @SubChunk) = (@_);
  my ($Line);
  foreach $Line (@SubChunk) {
    # skip lines that look like nested SubChunk headers
    next if ($Line =~ /^[+-]{$DiffLevel}(\+\+|--) /x);
    if ($Line =~ /^[+-]{$DiffLevel}.*\S.*$/x) {
      return 1;
    }
   }
  return 0;
}

sub StripWhiteSpaceChangesInSubChunk() {
  # strips all isolated whitespace changes
  # isolated whitespace are context lines followed by
  # only whitespace substracts or deletes
  # followed by context lines
  my ($DiffLevel, @SubChunk) = (@_);
  my (@Types) = map { '0' } @SubChunk;
  $Types[0] = 'c';

  for (my $i = 1;
       $i <= $#SubChunk;
       ++$i) {
    my ($Line) = $SubChunk[$i];
    # Skip diffs to context lines
    next if ($Line =~ /^[+-]{$DiffLevel} (\+\+|--)\s/x);
    if ($Line =~ /^ /) {
      $Types[$i] = 'c';
    } elsif ($Line =~ /^[+-]{$DiffLevel}\s*$/x) {
      $Types[$i] = 'w';
    } else {
      $Types[$i] = 'x';
    }
  }
  
  if (0) {
    foreach (0 .. $#SubChunk) {
      print "$Types[$_]: ", $SubChunk[$_];
    }
    print "\n\n\nNow trying to reset all isolated whitespace changes\n";
  }
  my ($i,$safe,$j) = (1,0,0);
  my @safelines;
  while ($i <= $#SubChunk) {
    if ($Types[$i] eq 'c') {
      $safe = 1; next;
    } elsif ($Types[$i] eq 'x') {
      $safe = 0; next;
    }
    if (($Types[$i] eq 'w') && $safe) {
      # scan forward and see if the whitespace run remains safe.
      $j = $i+1 if ($j < $#SubChunk);
      while ($safe && ($j <= $#SubChunk)) {
        last if ($Types[$j] eq 'c');
        if ($Types[$j] eq 'w') {
          next;
        }
        $safe = 0;
        $i = $j+1;
      } continue {  $j++;  }

      if ($safe) {
        while ($i <= $j) {
          my ($Line) = $SubChunk[$i];
          if (substr($Line,0,1) eq '-') {
            $Types[$i] = 'c';
            # only thing that needs to happen is to get rid of the '-' and turn it
            # into a context line
            $SubChunk[$i] = " " . substr($Line,1);
          } elsif (substr($Line,0,1) eq '+') {
            splice(@Types, $i, 1);
            splice(@SubChunk, $i, 1);
            $j--; $i--;
          }
        } continue { $i++; }
      }
    }
  } continue { $i++; }
  if (0) {
    foreach (0 .. $#SubChunk) {
      print "$Types[$_]: ", $SubChunk[$_];
    }
    print "\n";
  }
  return @SubChunk;
}

sub AdjustAllSubchunkHeaders {
  # in place operation
  my ($File, @Chunk) = (@_);
  my ($Shift) = 0;
  my (@SubChunk, @DstChunk);
  my $i;
  ($#Chunk >= 2) || die "@Chunk is incomplete";
  push @DstChunk, shift @Chunk;
  push @DstChunk, shift @Chunk;
  push @DstChunk, shift @Chunk;

  $i = 0; # don't worry about the header
  while ($i <= $#Chunk) {
    my $Line = $Chunk[$i];
    if ($Line =~ /^@@ /) {
      if ($#SubChunk > 2)  { # to avoid calling this routine at the very start...
        push @DstChunk, &AdjustSubchunkHeader(\$Shift, @SubChunk);
      }
      @SubChunk = ();
    }
    push @SubChunk, $Line;
  } continue {
    $i++;
  }

  if ($#SubChunk > 2) {
    push @DstChunk, &AdjustSubchunkHeader(\$Shift, @SubChunk);
  }
  print $File @DstChunk if ($#DstChunk > 2 && $File ne '');
  return @Chunk;
}

sub AdjustSubchunkHeader {
  my ($rtn, @SubChunk) = (@_);
  my ($i, $add, $sub) = (1, 0,0);
  if ($SubChunk[0] =~ /^@@\s*\-([0-9]+)(,([0-9]+)?)?(\s+\+([0-9]+)(,([0-9]+)?)?)?\s*@@/) {
    my ($SrcLine,$SrcMod,$DstLine,$DstMod) = ($1, $3, $5, $7);
    $SrcMod = 1 if ($SrcMod eq '');
    $DstMod = 1 if ($DstMod eq '');
    $DstLine = $SrcLine + ${$rtn} if ($DstLine eq '');
    while ($i <= $#SubChunk) {
      next if ($SubChunk[$i] =~ /^ /);
      $sub++ if (substr($SubChunk[$i],0,1) eq '-');
      $add++ if (substr($SubChunk[$i],0,1) eq '+');
    } continue { $i++; }
    my($L) = $#SubChunk; # num of lines in subchunk minus header
    $SrcMod = $L - $add;
    $DstMod = $L - $sub;
    ${$rtn} = ${$rtn} + ($DstMod - $SrcMod);
    $DstLine = $SrcLine;
    $SubChunk[0] = "@@ -${SrcLine},${SrcMod} +${DstLine},${DstMod} @@\n";
  }
  return @SubChunk;
}


sub HgCommitMqRefresh {
  # To be run after a successful refresh step.
  # Pre: all patches are already pushed and refreshed

  my ($RepoDir, $BaseRev) = (@_);
  my ($CMD, $RepoRoot) =  &GetRepoRoot($RepoDir);
  print "Attemting to commit the following changes";
  Shell("hg stat", "Main Repo Status");
  Shell("hg -R .hg/patches stat", "Patch Repo Status");
  my (%RevLog) = &GetHgLog($BaseRev);
  print "Commiting Rebase to the following version\n";
  &WriteLog(\ %RevLog);
  print "Are you sure you are merging for '$RevLog{rev}'? :";
  $_ = <STDIN>;
  die "Ok, aborting\n" if (! /y(e(s)?)?/i );
  #print "Double checking to make sure you aren't mistaken\n";
  #my (@MqSeries) = grep { chomp } Shell("hg qapplied", "get series");
  #Shell("hg qpop -a", "Double check");
  #my (%ActualRevB4Patch) = &GetHgLog('');
  #die "You LIE! Revs don't match -- its actually ${ActualRevB4Patch}{rev}\n"
  #  if ($ActualRevB4Patch{rev} ne $RevLog{rev});
  #&HgPushLoop(@MqSeries);
  my ($RevName) = &GetRevName(%RevLog);
  my (@AllBranches) = grep { chomp } Piped("hg -R .hg/patches branches -a");
  if (grep { /^${RevName}\s/x } @AllBranches) {
    print "Branch $RevName already exists\n";
  } else {
    print "Creating new branch $RevName\n";
    Shell("hg -R .hg/patches branch $RevName", "");
  }
  Shell("hg commit -R .hg/patches", "COMMIT THE BRANCH");
};

sub ArgvHasFlag {
  # returns the list of matching options
  my ($flag) = @_;

  return grep { /^${flag}$/x } (@ARGV);
}

sub ArgvHasOpt {
  #1. for -Option R
  #2. for -Option=R
  #3. for -OptionR
  my ($flag) = @_;
  my ($seenOption) = 0;
  my (@Rtn, $i);
  
  foreach $i (0 .. $#ARGV) {
    $_ =$ARGV[$i];
    if ($seenOption) {
      die "illegal ${\($i+1)} th arg '$_'\n" if (/^$flag/x);
      push @Rtn, $_;
      $seenOption = 0;
    } elsif (/^${flag}$/) {
      $seenOption = 1;
    } elsif (/^${flag}=(.*)$/) {
      push (@Rtn, $1);
    } elsif (/^${flag}(.*)$/) {
      push (@Rtn, $1);
    }
  }
  return (@Rtn);
}


sub ArgvHasUniqueOpt {
  my ($flag, $var) = @_;
  my (@Rtn) = &ArgvHasOpt($flag);
  die "Can't have more than one '$_[0]'\n" if ($#Rtn > 0);
  return $$var = $Rtn[0] if ($#Rtn == 0);
  return 0;
}

sub GetRepoRoot {
  my ($CMD) = "";
  my ($Dir) = (@_);
  my ($Orig); chomp($Orig =`pwd`);

  chdir $Dir || die "Unable to chdir to $Dir from ", `pwd`;
  chomp($Dir=`pwd`);  
  while ($Dir ne "/") {
    if (-d ".svn") {
      $CMD = "svn"; last;
    } elsif (-d ".hg") {
      $CMD = "hg"; last;
    }
    chdir ("..");
    chomp($Dir = `pwd`);

  }
  print "Now In $Dir $CMD\n";
  chdir $Orig;
  die "Unable to determine Repo type for '$Orig'\n" if ($CMD eq "");
  return ($CMD, $Dir);
}

sub QuoteIt {
  my ($Cmd) = (@_);
  $Cmd =~ s/\n/\\n/g;
  $Cmd =~ s/\t/\\t/g;
  return $Cmd;
}

sub Shell {
  my ($Cmd, $Comment) = @_;
  my ($CWD) = `pwd`;
  chomp ($CWD);
  print "# $Comment " if ($Comment ne '');
  my $Cmd2 = &QuoteIt($Cmd);
  print "(cd $CWD; $Cmd2)\n";
  system($Cmd) == 0 || 
    die "- $Cmd failed: $?";
}

sub Piped {
  my ($Cmd, $Comment) = @_;
  my ($CWD) = `pwd`;
  chomp ($CWD);
  my ($Fh);
  if ($Cmd !~ /\s\|\s*$/) {
    $Cmd = "$Cmd | ";
  }
  my $Cmd2 = &QuoteIt($Cmd);

  open($Fh, $Cmd) ||
    die "Unable to execute '$Cmd2' as readpipe\n";
  print "# PIPE ";
  print "$Comment " if ($Comment ne '');
  print "(cd $CWD; $Cmd2 )\n";
  my @List = <$Fh>;
  close ($Fh);
  return @List;
}

sub Piped2 {
  my ($Comment, @Cmd) = @_;
  my ($CWD) = `pwd`;
  chomp ($CWD);
  my ($Fh);
  my $Cmd2 = &QuoteIt(join(" ", @Cmd));

  open($Fh, "-|", @Cmd) ||
    die "Unable to execute '$Cmd2' as readpipe\n";
  print "# PIPE ";
  print "$Comment " if ($Comment ne '');
  print "(cd $CWD; $Cmd2 )\n";
  my @List = <$Fh>;
  close ($Fh);
  return @List;
}

sub MergePatchHeader {
  my ($Src, $Dst, $PatchName) = @_;

  print "Merging the patch header from '$Src' to '$Dst'\n";
  open(my $SrcFh, $Src) 
    || die "Unable to open source patch '$Src'\n";
  open(my $DstFh, $Dst) 
    || die "Unable to open destination patch '$Dst'\n";

  my (@Src) = <$SrcFh>;
  my (@Dst) = <$DstFh>;
  close($SrcFh);
  close ($DstFh);
  my (@Header);
  
  while (1) {
    last if ($Src[0] =~ /^diff /);
    push @Header, shift @Src;
  }
  while (1) {
    last if ($Dst[0] =~ /^diff /);
    shift (@Dst)
  }

  push @Header, " From $PatchName\n";
  open ($DstFh, ">$Dst")
    || die "Unable to write to destination patch '$Dst'\n";
  print $DstFh @Header;
  print $DstFh @Dst;
}


sub GetHgLog {
  # get important info about the current rev
  my ($CurrHgRev) = @_;
  if ($CurrHgRev eq '') {
    my (@Rev) = grep { chomp; } Piped("hg id -i", "Getting current rev");
    $CurrHgRev =  shift @Rev;
    $CurrHgRev =~ s/\+$//g; ## kill any trailing '+'
  }
  my (@Log) = 
    Piped2("Getting Log info for '$CurrHgRev'",
           ("hg", "log", 
            "--debug", "--template=rev:\t\t{rev}:{node}\n".
            "svn:\t\t{svnrev}\n".
            "branches:\t\t{branches}\ntags:\t\t{tags}\n" .
            "children:\t{children}\nparents:\t{parents}\n",
            "-r", ${CurrHgRev}));
  # print @Log;

  my (%Rtn);
  foreach (@Log) {
    $_ =~ /^(\w+):\s+(.*)$/;
    my $Key = $1;
    my $Rest = $2;
    $Rtn{$Key} = $Rest;
    # print "  $Key -> $Rest\n";
  }
  return %Rtn;
}

sub WriteLog {
  my ($Rtn) = (@_);
  my ($Key);
  
  format =
@<<<<<<<<<<<<@<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$Key, ${$Rtn}{$Key}
.
  my (@keys) = (qw(rev children parents svn tags branches));
  # last line of defense
  foreach (@keys) {
    die "Something went wrong with quering the repository (key $_ is missing)\n" 
      if (! exists ${$Rtn}{$_});;
  }


  foreach $Key (qw(rev children parents svn tags branches)) {
    write;
  }
}

sub GetRevName {
  my (%Log) = @_;
  my ($Rtn) = '';
  my (@tmp);

  if ($Log{svn} ne '') {
    $Rtn = "svn${Log{svn}}";
  } elsif (@tmp = split($Log{tags})) {
    $Rtn = "tag$tmp[0]";
  } else {
    # worst case - use the short id
    @tmp = split(/:/, $Log{rev});
    $Rtn = "rev$tmp[0]";
  }
  return $Rtn;
}

sub SaveTestArtifacts() {
  my($VersionTag, $DstDir, @Dirs) = (@_);
  my($Dir);
  my(@AllArtifacts);
  foreach $Dir (@Dirs) {
    my (@MD5Sums) = Piped("find $Dir -type f | xargs md5sum", "");
    push @AllArtifacts, @MD5Sums;
  }
  @AllArtifacts = sort @AllArtifacts;
  my ($Artifact, $PriorMD5Sum, $PriorArtifact) = ('', '');
  Shell("rm -rf $DstDir/$VersionTag", "");
  Shell("mkdir -p $DstDir/$VersionTag", "");
  $DstDir = "$DstDir/$VersionTag";

  foreach  (@AllArtifacts) {
    chomp;
    /^([a-z0-9]+)\s+(\S.*)$/;
    my ($MD5Sum, $Artifact) = ($1, $2);
    my($A, $P) = &fileparse($Artifact);
    Shell("mkdir -p ${DstDir}/${P}", "");
    if ($MD5Sum eq $PriorMD5Sum) {
      print "  REPEAT $Artifact\n";
      Shell("ln -s -f ${DstDir}/${PriorArtifact} ${DstDir}/${Artifact}", "");
    } else {
      $PriorMD5Sum = $MD5Sum;
      $PriorArtifact = $Artifact;
      print "$MD5Sum // $Artifact\n";
      Shell("cp -a ${Artifact} ${DstDir}/${Artifact}", "");
    }
  }
}

1;

