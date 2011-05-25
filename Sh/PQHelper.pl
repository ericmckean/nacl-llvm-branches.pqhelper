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

sub Shell {
  my ($Cmd) = @_;
  my ($CWD) = `pwd`;
  chomp ($CWD);
  print "In $CWD exec $Cmd\n";
  system($Cmd) == 0 || 
    die "- $Cmd failed: $?";
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
  Shell("hg qinit -c") if (! -d ".hg/patches/.hg");
  Shell("hg qpop -a");
  {
    chdir ".hg/patches";
    Shell("hg tag ${TagStr} -r tip");
    chdir "../..";
  };
  
  foreach $Entry (@{$PatchList}) {
    print "Processing $Entry\n";
    my ($PatchName, $directories) = fileparse($Entry);
    Shell("patch ${PatchOptions} < ${Entry}");
    &HgTrackPatch($RepoRoot);
    Shell("hg qnew -f ${PatchName}");
  }
  
  print "Done importing patches. " .
    "Examine the state of the repo and Execute -I2\n";
}

sub HgRevertClean() {
  my ($RepoDir) = @_;
  my ($CMD, $RepoRoot) =  GetRepoRoot($RepoDir);
  chdir $RepoRoot;
  die "$RepoRoot is not a hg repo\n" if ("hg" ne $CMD);
  Shell("hg revert -a .");
  my (@Files) = map { chomp; $_ = substr($_,2) } grep { /^?/ } `hg stat -u`;
  print "Removing:\n\t", join("\n\t", @Files), "\n" if ($#Files >= 0);
  my ($Count) = unlink @Files;
  die "Unable to cleanly revert $RepoRoot $Count\n" if ($Count != ($#Files+1));
}

sub HgRefreshAll {
  my ($RepoDir) = @_;
  my ($CMD, $RepoRoot) =  GetRepoRoot($RepoDir);
  chdir $RepoRoot;
  open (my $PList, "hg qseries |") || 
    die "Unable to get qseries in '$RepoRoot'\n";
  Shell("hg qpop -a");
  my (@PatchList) = <$PList>;
  close $PList;
  &HgRefreshLoop(@PatchList);
}

sub HgRefreshLoop() {
  my (@PatchList) = @_;
  my ($MqPatch);
  
  foreach $MqPatch (@PatchList) {
    chomp $MqPatch;
    print "Processing $MqPatch\n";
    Shell("hg qpush $MqPatch");
    Shell("hg qrefresh");
  }
  Shell("hg -R .hg/patches stat");
}


sub HgContinueRefresh {
  ## called when a HgRefreshAll has failed and a manual intervention was required
  ## the repo must be clean, with no orig or reg
  open (my $PList, "hg qseries |") || 
    die "Unable to get qseries in '$RepoRoot'\n";
  my(@MqSeries) = <$PList>;
  close $PList;
  
  open (my $Applied, "hg qapplied |") || 
    die "Unable to get hg qapplied in '$RepoRoot'\n";
  my (@MqApplied) = <$Applied>;
  map { my($x) = shift @MqSeries;
        $x eq $_ || die "hg qapplied does not look like declared qseries!\n";
      } @MqApplied;
  &HgRefreshLoop(@MqSeries);
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
  my ($DiffLevel, @Chunk) = (@_);
  my (@SubChunk);
  my (@DstChunk);

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
  Shell("hg add ${\(join(' ', @ToBeAdded))}") if ($#ToBeAdded >= 0);
  Shell("hg delete ${\(join(' ', @ToBeDeleted))}") if ($#ToBeDeleted >= 0);
}

$PatchDir="/tmp/out";
opendir(my $dh, $PatchDir) || die "can't opendir the patch directory $PatchDir: $!";
@PatchList = map { $_ = "${PatchDir}/$_" }
  grep { -f "${PatchDir}/$_" } readdir($dh);
closedir $dh;

print "PatchList $#PatchDir\n";
chomp($_ = `pwd`);

  if (grep { /^-Clean$/ } @ARGV) {
    &HgRevertClean($_);
    &HgRevertClean("$_/.hg/patches");
  } elsif (grep { /^-Init$/ } @ARGV) {
    &InitPatchQueue("-p2 -s", \@PatchList,  $_, "23195", "r124151");
  } elsif (grep { /^-Track$/ } @ARGV) {
    &HgTrackPatch($_);
  } elsif (grep { /^-Refresh$/ } @ARGV) {
    &HgRefreshAll($_);
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
    die "not supported yet\n";
  } else {
    print "-Clean (Clean and Revert) or -I (Init) or -T (track) or -Refresh\n";
    print "-Track\n";
    print "-Refresh\n";
    print "-DelWhiteSpace PatchFiles... safely removes all diff subchunks with only whitespace changes\n";
    print "-VerifyDiffIsWhite {DiffLevel} PatchesOrCommands)... \n";
    print "  Optional DiffLevel argument:\n";
    print "  DiffLevel is -d1 (default), -d2, -d3 ... \n";
    print "  where 1 is a single diff, 2 is a diff of a diff, 3 is a diff or a diff of a diff..\n";
    print "  DiffLevel > 1 is necessary to discern what happens if your change is to a patch file.";
    print "  -VerifyDiffIsWhite smartly ignores changes to nested context lines.\n";
    print "  For example: -VerifyDiffIsWhite -d2 'diff -u A.patch B.patch'";
    print "   examines the lines resulting from diff -u A.patch B.patch | egrep '^[+-]{2}' | egrep -v '^[+-]{2}(\+\+|--) '
    print "-StripAllWhiteSpace\n";
    print "  Removes all isolated whitespace diffs i.e. not whitespace diffs that are not contiguous\n";
    print "  with real diffs. Uses the DiffLevel argument\n";
  }
