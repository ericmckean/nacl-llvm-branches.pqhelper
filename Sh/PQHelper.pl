#!/usr/bin/perl -w
# -w
# -*- perl -*-

use File::Basename;
#use IPC::System::Simple;
#use autodie qw(:all);

sub GetRepoRoot {
  my ($CMD) = "";
  my ($Dir) = (@_);
  my ($Orig) = $Dir;

  chdir $Dir;
  while ($Dir ne "/") {
    if (-d ".svn") {
      $CMD = "svn"; last;
    } elsif (-d ".hg") {
      $CMD = "hg"; last;
    }
    chdir ("..");
    chomp($Dir = `pwd`);
    # print "Now In $Dir $CMD\n"
  }

  chdir $Orig;
  die "Unable to determine Repo type for '$Orig'\n" if ($CMD eq "");
  return ($CMD, $Dir);
}

sub QuoteIt() {
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
  print "# PIPE\n";
  print "(cd $CWD; $Cmd2 )\n";
  my @List = <$Fh>;
  close ($Fh);
  return @List;
}


sub InitPatchQueue() {
  my ($PatchOptions, $PatchList, $RepoDir, $BaseRev, $TagStr) = @_;
  my ($Orig);
  chomp($Orig = `pwd`);

  my($CMD, $RepoRoot) = &GetRepoRoot($RepoDir);

  print "TYPE: $CMD, $RepoRoot $#$PatchList\n";
  chdir $RepoRoot;

  &HgRevertClean($RepoRoot);
  system("hg up -r $BaseRev") == 0 ||
    die "Unable to update Repo $RepoRoot to rev '$BaseRev'\n";
  Shell("hg qinit -c", "") if (! -d ".hg/patches/.hg");
  Shell("hg qpop -a", "");
  {
    chdir ".hg/patches";
    Shell("hg tag -l ${TagStr} -r tip", "");
    chdir "../..";
  };

  foreach $Entry (@{$PatchList}) {
    print "Processing $Entry\n";
    my ($PatchName, $directories) = fileparse($Entry);
    Shell("patch ${PatchOptions} < ${Entry}", "");
    &HgTrackPatch($RepoRoot);
    Shell("hg qnew -f ${PatchName}", "");
  }
  
  print "Done importing patches. " .
    "Examine the state of the repo and Execute -I2\n";
}

sub HgRevertClean() {
  my ($RepoDir) = @_;
  my ($CMD, $RepoRoot) =  GetRepoRoot($RepoDir);
  chdir $RepoRoot;
  die "$RepoRoot is not a hg repo\n" if ("hg" ne $CMD);
  Shell("hg revert -a .", "");
  my (@Files) = map { chomp; $_ = substr($_,2) } grep { /^?/ } `hg stat -u`;
  print "Removing:\n\t", join("\n\t", @Files), "\n" if ($#Files >= 0);
  my ($Count) = unlink @Files;
  die "Unable to cleanly revert $RepoRoot $Count\n" if ($Count != ($#Files+1));
}

sub HgRefreshAll {
  my ($RepoDir, $BaseRev, $QBaseRev) = @_;
  my ($CMD, $RepoRoot) =  GetRepoRoot($RepoDir);
  
  if ($BaseRev eq '') {
    my (%Log) = &GetHgLog('');
    $BaseRev = $Log{"svn"};
  }
  if ($QBaseRev ne '') {
    Shell("hg -R .hg/patches up -r $QBaseRev", "");
  }

  chdir $RepoRoot;
  Shell("hg qpop -a", "");
  my (@PatchList) = Piped("hg qseries", "");
  &HgRefreshLoop(@PatchList);
}

sub HgRefreshLoop() {
  my (@PatchList) = @_;
  my ($MqPatch);
  
  foreach $MqPatch (@PatchList) {
    last if ($MqPatch eq "STOP");
    chomp $MqPatch;
    print "Processing $MqPatch\n";
    Shell("hg qpush $MqPatch", "", "");
    Shell("hg qrefresh", "", "");
  }
  Shell("hg -R .hg/patches stat", "", "");
}

sub HgContinueRefresh {
  ## called when a HgRefreshAll has failed and a manual intervention was required
  ## the repo must be clean, with no orig or reg
  my(@MqSeries) = Piped("hg qseries");
  my (@MqApplied) = Piped("hg qapplied");
  map { my($x) = shift @MqSeries;
        $x eq $_ || die "hg qapplied does not look like declared qseries!\n";
      } @MqApplied;
  &HgRefreshLoop(@MqSeries);
}

sub HgCommitMqRefresh {
  # To be run after a successful refresh step.
  # Pre: all patches are already pushed and refreshed

  my ($RepoDir, $BaseRev) = (@_);
  my ($CMD, $RepoRoot) =  &GetRepoRoot($RepoDir);

  my (%RevLog) = GetHgLog($BaseRev);
  print "Commiting Rebase to the following version\n";
  write();
  my (@AllBranches) = grep { chomp } Piped("hg -R .hg/patches branches -a");
  if (grep { /^svn${RevLog{svn}}\S/x } @AllBranches) {
    print "Branch svn${RevLog{svn}} exists\n";
  } else {
    print "Creating new branch svn${RevLog{svn}}\n";
    Shell("hg -R .hg/patches branch svn${RevLog{svn}}", "", "");
  }
  Shell("hg commit", "", "");
};

sub GetHgLog {
  # get important info about the current rev
  my ($CurrHgRev) = @_;
  if ($CurrHgRev eq '') {
    my (@Rev) = grep { chomp; } Piped("hg id -i");
    $CurrHgRev =  shift @Rev;
  }

  my (@Log) = 
    Piped("hg log --debug --template='rev:\t\t{rev}:{node|short}\n".
          "svn:\t\t{svnrev}\n".
          "branches:\t\t{branches}\ntags:\t\t{tags}\n" .
          "children:\t{children}\nparents:\t{parents}\n'".
          " -r ${CurrHgRev}");
  # print @Log;

  my (%Rtn);
  foreach (@Log) {
    $_ =~ /^(\w+):\s+(.*)$/;
    my $Key = $1;
    my $Rest = $2;
    $Rtn{$Key} = $Rest;
  }
  return %Rtn;
}

sub ProcessPatch () {
  # @Chunk (for --unified diffs) has:
  # diff ...
  # --- ...
  # +++ ...
  # followed by one or more SubChunk
  # @@ ...

  my ($Func, $Arg, @Lines) = (@_);
  my $Line;
  my $DiffStart = '';
  my @Chunk;
  foreach $Line (@Lines) {
    if ($Line =~ /^diff /) {
      $DiffStart = $Line;
      &$Func($Arg, @Chunk) if ($#Chunk > 0);
      # clear Chunk out for next bit
      @Chunk = ();
    }
    push @Chunk, $Line;
  }
  &$Func($Arg, @Chunk)  if ($#Chunk >= 2);
}


sub StripWhiteSpace {
  my ($FH, @Chunk) = (@_);
  my (@SubChunk);
  my (@DstChunk);
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
  print $FH @DstChunk if ($#DstChunk > 2);
}

sub VerifyDiffIsWhite() {
  my ($DiffLevel, @Chunk) = (@_);
  my (@SubChunk);
  my (@DstChunk);

  ($#Chunk >= 2) || die "@Chunk is incomplete";
  push @DstChunk, shift @Chunk;
  push @DstChunk, shift @Chunk;
  push @DstChunk, shift @Chunk;
  
  foreach $Line (@Chunk) {
    if ($Line =~ /^@@ /) {
      if (($#SubChunk > 0) && &SubChunkHasNonBlankDelta($DiffLevel, @SubChunk)) {
        push @DstChunk, @SubChunk;
      }
      @SubChunk = ();
    }
    push @SubChunk, $Line;
  }
  if ( ($#SubChunk > 0) && &SubChunkHasNonBlankDelta($DiffLevel, @SubChunk)) {
    push @DstChunk, @SubChunk;
  }
  if ($#DstChunk > 2) {
    print "******** Non-whitespace Diffchunk found *****\n";
    print @DstChunk;
    return 0;
  }
  return 1;
};


sub SubChunkHasNonBlankDelta() {
  my ($DiffLevel, @SubChunk) = (@_);
  foreach $Line (@SubChunk) {
    # skip lines that look like nested SubChunk headers
    next if ($Line =~ /^[+-]{$DiffLevel}(\+\+|--) /x);
    if ($Line =~ /^[+-]{$DiffLevel}.*\S.*$/x) {
      return 1;
    }
   }
  return 0;
}

sub StripAllWhiteSpace() {
  my ($Assoc, @Chunk) = (@_);
  my (@SubChunk);
  my (@DstChunk);
  my ($DiffLevel) = $$Assoc{"DiffLevel"};
  my ($File) = $$Assoc{"File"};

  ($#Chunk >= 2) || die "@Chunk is incomplete";
  push @DstChunk, shift @Chunk;
  push @DstChunk, shift @Chunk;
  push @DstChunk, shift @Chunk;
  
  foreach $Line (@Chunk) {
    if ($Line =~ /^@@ /) {
      if ($#SubChunk > 0)  {
        push @DstChunk, &StripWhiteSpaceChangesInSubChunk($DiffLevel, @SubChunk);
      }
      @SubChunk = ();
    }
    push @SubChunk, $Line;
  }
  if ($#SubChunk > 0)  {
    push @DstChunk,  &StripWhiteSpaceChangesInSubChunk($DiffLevel, @SubChunk);
  }
  
  open(my $Dst, "> $File") || 
    die "Unable to create '$File'\n";
  return @DstChunk;
};

sub StripWhiteSpaceChangesInSubChunk() {
  # strips all isolated whitespace changes
  # isolated whitespace are context lines followed by
  # only whitespace substracts or deletes
  # followed by context lines
  my ($DiffLevel, @SubChunk) = (@_);
  my (@Types) = map { '0' } @SubChunk;
  
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
  push @Types, 'c';

  my $i = 1;
  while ($i <= $#SubChunk) {
    my ($Line) = $SubChunk[$i];
    if (($Types[$i] eq 'w') && 
        (($Types[$i-1] eq 'c') || ($Types[$i-1] eq 'w')) &&
        (($Types[$i+1] eq 'c') || ($Types[$i+1] eq 'w'))) {
      if (substr($Line,0,1) eq '-') {
        $Types[$i] = 'c';
        # only thing that needs to happen is to get rid of the '-' and turn it
        # into a context line
        $SubChunk[$i] = " " . substr($Line,1);
        $i++;
      } elsif (substr($Line,0,1) eq '+') {
        $Types[$i] = $Types[$i+1];
        splice(@SubChunk, $i, 1);
      }
    } else {
      $i++;
    }
  }
  return @SubChunk;
}


sub HgTrackPatch {
  my ($RepoDir) = @_;
  my ($CMD, $RepoRoot) =  GetRepoRoot($RepoDir);
  chdir $RepoRoot;
  my @Files = `hg stat`;
  my (@ToBeDeleted) = map { chomp; $_ = substr($_, 2) } grep { /^\!/ } @Files;
  my (@ToBeAdded) = map { chomp; $_ = substr($_, 2) }
    grep { !/(orig|rej)$/ }
    grep { /^\?/ } @Files;
  Shell("hg add ${\(join(' ', @ToBeAdded))}", "") if ($#ToBeAdded >= 0);
  Shell("hg delete ${\(join(' ', @ToBeDeleted))}", "") if ($#ToBeDeleted >= 0);
}

chomp($_ = `pwd`);

  if (grep { /^-Clean$/ } @ARGV) {
    &HgRevertClean($_);
    &HgRevertClean("$_/.hg/patches");
  } elsif (grep { /^-Init$/ } @ARGV) {
#     my (@Args) = grep { !/^-\w+$/ 
#                       } @ARGV;
#     my ($PatchDir, $PatchOpts, $Tag, $Rev);
    
     $PatchDir="/tmp/out";
     opendir(my $dh, $PatchDir) || die "can't opendir the patch directory $PatchDir: $!";
     @PatchList = map { $_ = "${PatchDir}/$_" }
       grep { -f "${PatchDir}/$_" } readdir($dh);
     closedir $dh;

#     print "PatchList $#PatchDir\n";

    &InitPatchQueue("-p2 -s", \@PatchList,  $_, "23195", "r124151");
  } elsif (grep { /^-Track$/ } @ARGV) {
    &HgTrackPatch($_);
  } elsif (grep { /^-Refresh$/ } @ARGV) {
    &HgRefreshAll($_);
  } elsif (grep { /^-ContinueRefresh$/ } @ARGV) {
    &HgContinueRefresh($_);
  } elsif (grep { /^-CommitRefresh$/ } @ARGV) {
    my (@Revs) = grep { chomp } grep { /^-r\S+$/ } @ARGV;    
    if ($#Revs >= 0 && length($Revs[-1]) > 2) {
      my ($Rev) = substr($Revs[-1], 2);
      &HgCommitMqRefresh($_, $Rev);
    }
  } elsif (grep { /^-DelWhiteSpace$/ } @ARGV) {
    my (@Patches) = grep { !/^-\w*$/ } @ARGV;
    print "Processing:\n\t", join("\n\t",@Patches), "\n" if ($#Patches >= 0);
    for $File (@Patches) {
      open (my $Fh, "$File") || die "Unable to open patch '$File' for reading\n";
      my (@Lines) = <$Fh>;
      close $Fh;
      open (my $DstFh, ">${File}.stripped") || 
        die "Unable to open ${File}.stripped for writing\n";
      &ProcessPatch(\&StripWhiteSpace, $DstFh, @Lines);
      close $DstFh;
    }
  } elsif (grep { /^-VerifyDiffIsWhite$/ } @ARGV) {
    my (@DiffLevels) = grep { /^-d[1-9]$/
                          } @ARGV;
    my($DiffLevel) = 1;
    $DiffLevel = substr($DiffLevels[-1], 2) if ($#DiffLevels > -1);

    my (@Patches) = grep { !/^-\w*$/ } @ARGV;
    my ($Rtn) = 1;
    print "In ", `pwd`;

    foreach $FileOrCmd (@Patches) {
      my ($Fh, @Lines);
      if (-e $FileOrCmd) {
        open ($Fh, "$FileOrCmd") || 
          die "Unable to open patch '$FileOrCmd' for reading $?\n";
      } else {
        open($Fh, "$FileOrCmd | ") ||
          die "Unable to open command '$FileOrCmd |' for reading $?\n";
      }
      @Lines = <$Fh>;
      close ($Fh);
      $Rtn &= &ProcessPatch(\&VerifyDiffIsWhite, $DiffLevel, @Lines);
      $Rtn || die "Non-whitespace change in '$FileOrCmd'\n";
    }
  } elsif (grep { /^-StripAllWhiteSpace$/ } @ARGV) {
    die "ACk!\n"; 
  } elsif (grep { /^-Log$/ } @ARGV) {
    my (@Revs) = grep { /^-r\S+$/ } @ARGV;
    my (%Rtn);

    if ($#Revs >= 0) {
      foreach (@Revs) {
        $_ = substr($_,2);
        print "Trying REV $_\n";
        %Rtn = &GetHgLog("'$_'");
        foreach $Key (qw(rev children parents svn tags branches)) {
          write;
        }
      }
    } else {
      %Rtn = &GetHgLog('');
      foreach $Key (qw(rev children parents svn tags branches)) {
        write;
      }
    }
    format =
@<<<<<<<<<<<<@<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<
$Key, $Rtn{$Key}
.
  } else {
    print "-Clean (Clean and Revert) or -I (Init) or -T (track) or -Refresh\n";
    print "-Track\n";
    print "-Refresh\n" .
      "  attempts to start a new rebase operation on the current revision\n";
    print "-ContinueRefresh\n" .
      " Attempts to continue the refresh operation\n"
    print "-CommitRefresh\n" .
      "

    print "-Log (-rREV)\n";
    print "-Clean -- be careful of files hidden from view via .hgignore\n";
    print "-DelWhiteSpace PatchFiles... safely removes all diff subchunks with only whitespace changes\n";
    print "-VerifyDiffIsWhite {DiffLevel} PatchesOrCommands)... \n" .
     "  Optional DiffLevel argument:\n" . 
     "  DiffLevel is -d1 (default), -d2, -d3 ... \n" .
     "  where 1 is a single diff, 2 is a diff of a diff, 3 is a diff or a diff of a diff..\n" .
     "  DiffLevel > 1 is necessary to discern what happens if your change is to a patch file." .
     "  -VerifyDiffIsWhite smartly ignores changes to nested context lines.\n" .
     "  For example: -VerifyDiffIsWhite -d2 'diff -u A.patch B.patch'" .
     "   examines the lines resulting from diff -u A.patch B.patch | egrep '^[+-]{2}' | egrep -v '^[+-]{2}(\+\+|--) '\n";
    print "-StripAllWhiteSpace\n" .
     "  Removes all isolated whitespace diffs i.e. not whitespace diffs that are not contiguous\n". 
     "  with real diffs. Uses the DiffLevel argument\n";
  }

## first bad revision 23197
