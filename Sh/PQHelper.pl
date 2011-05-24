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
  foreach $MqPatch (<$PList>) {
    chomp $MqPatch;
    print "Processing $MqPatch\n";
    Shell("hg qpush $MqPatch");
    Shell("hg qrefresh");
  }
  
  Shell("hg -R ${RepoRoot}/.hg/patches stat");
  close $PList;
}

sub ProcessPatch () {
  my ($Func, $Arg, @Lines) = (@_);
  my $Line;
  my $DiffStart = '';
  my @Chunk;
  foreach $Line (@Lines) {
    if ($Line =~ /^diff /) {
      $DiffStart = $Line;
      &HandleChunk($Dir, @Chunk);
      # clear Chunk out for next bit
      @Chunk = ();
    }
    push @Chunk, $Line;
  }
  &$Func($Arg, @Chunk)  if ($#Chunk >= 2);
}


sub StripWhiteSpaceChunks {
  sub
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
  } elsif (grep { /^-Track/ } @ARGV) {
    &HgTrackPatch($_);
  } elsif (grep { /^-Refresh/ } @ARGV) {
    &HgRefreshAll($_);
  } else {
    print "-Clean (Clean and Revert) or -I (Init) or -T (track) or -R (Refresh)\n";
  }
  
