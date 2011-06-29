#!/usr/bin/perl 
# -w
# -*- perl -*-

use File::Basename;
use File::Temp qw/ tempfile tempdir /; ;
use English;
use Cwd;

my ($file, $path) = fileparse(Cwd::abs_path($PROGRAM_NAME));
push @INC, $path;

require RepoHelper || die "Install Error. Unable to find RepoHelper.pm\n";
print "$EXECUTABLE_NAME $PROGRAM_NAME ", Cwd::abs_path($PROGRAM_NAME), "\n";
import RepoHelper;

sub InitPatchQueue() {
  my ($PatchOptions, $PatchList, $RepoDir, $BaseRev, $Where) = @_;
  my ($Orig);
  chomp($Orig = `pwd`);

  my($CMD, $RepoRoot) = &GetRepoRoot($RepoDir);

  print "TYPE: $CMD, $RepoRoot $#$PatchList\n";
  chdir $RepoRoot;

  &HgRevertClean($RepoRoot);
  Shell("hg up -r '$BaseRev'", "") if ($BaseRev ne '');
  Shell("hg qinit -c", "") if (! -d ".hg/patches/.hg");

  my(@MqSeries) = Piped("hg qseries", "get patch sequence");
  my (@MqApplied) = Piped("hg qapplied", "get applied sequence");

  Shell("hg qpop -a", "");
  
  if ($Where eq "-FromStart") {
    # do nothing. 
    print "Starting import at the start\n";
    
  } elsif ($Where eq "-FromEnd") {
    map { my($x) = shift @MqSeries;
          $x eq $_ || die "hg qapplied does not look like declared qseries!\n";
        } @MqApplied;
    print "Starting import at $MqSeries[0]\n";
    &HgPushLoop(@MqSeries);
  } elsif ($Where eq "-FromNow") {
    &HgPushLoop(@MqApplied);
  }

  foreach $Entry (@{$PatchList}) {
    print "Processing $Entry\n";
    my ($PatchName, $directories) = fileparse($Entry);
    &Shell("patch ${PatchOptions} < ${Entry}", "");
    &HgTrackPatch($RepoRoot);
    &Shell("hg qnew -f ${PatchName}", "");
    &Shell("hg qpop", "pop the patch temporarily");
    &MergePatchHeader($Entry, ".hg/patches/${PatchName}", $PatchName);
    &Shell("hg qpush", "push the laast patch");
    &Shell("hg qrefresh", "refresh the last patch");
  }
  &TagRepo($RepoRoot, $BaseRev, "InitialImport");
  print "Done importing patches. " .
    "Examine the state of the repo and -CommitRefresh\n";
}

sub Foo {
  my ($SrcRepoDir, my $DstRepoDir) = @_;
  my ($Cmd1, $SrcRepo) = &GetRepoRoot($SrcRepoDir);
  my ($Cmd2, $DstRepo) = &GetRepoRoot($DstRepoDir);
  my (%L1);
  my (%L2);  

  print "SRC=$SrcRepo\n";
  print "DST=$DstRepo\n";

  chdir $SrcRepo;
  print "In ", `pwd`;
  %L1 = &GetHgLog('');
  &WriteLog(\%L1);

  chdir $DstRepo;
  print "In ", `pwd`;  
  %L2 = &GetHgLog('');
  &WriteLog(\%L2 );

  chdir $SrcRepo;
  print "In ", `pwd`;  
  %L1 = &GetHgLog('');
  &WriteLog(\ %L1 );

}


sub InitPatchQueueFromHgExport {

  my ($SrcRepoDir, $PatchOptions, $BaseRev, $EndRev, $DstRepoDir, 
      $DstBaseRev, $Where, $FirstParent) = @_;
  # Generates a set of patches from the source repository
  # and lands them as MQ patches in the destination repository.
  # Use this routine if the source and destination repos will not have
  # the same HashIds for their nodes for any reason. Otherwise, it should
  # be possible to hg pull the changesets directly, right?

  # Since it is not directly possible to maintain active branches while
  # a patch set queue is active, the active sequence of patches is always a
  # linear sequence. The MQ patches for any alternate branches are
  # directly sequenced into the active sequence, i.e. it is as if the
  # entire alternate branch was applied as a single rev.

  my ($UseTraditional) = 1;
  my ($SrcRepo, $DstRepo);
  my ($OrigDir); chomp ($OrigDir= `pwd`);
  my ($Cmd, $Base);

  ($Cmd, $SrcRepo) = &GetRepoRoot($SrcRepoDir);
  ($Cmd, $DstRepo) = &GetRepoRoot($DstRepoDir);

  chdir $DstRepo || die "YUK!";
  if ($DstBaseRev ne '') {
    Shell("hg up -r '$DstBaseRev'");
  }
  Shell("hg qinit -c", "") if (! -d ".hg/patches/.hg");

  my (@PatchSeq) = &Piped("hg qseries", "Get the existing patch series");
  my (@Applied) =  &Piped("hg qapplied", "How many patches are applied?");

  &HgRevertClean($DstRepo);
  print "SrcRepo $SrcRepo $SrcRepoDir DstRepo $DstRepo $DstRepoDir ", `pwd`;
  chdir $SrcRepo;
  print "SrcRepo $SrcRepo DstRepo $DstRepo ", `pwd`;
  my (@Path) = &FindEditPath($SrcRepo, $BaseRev, $EndRev);
  my ($LastRev, $Rev) = '';
  print "INININ ", `pwd`;
  # first, get the base revision - if it has two parents, abort!
  my ($FirstRev) = $Path[0];
  my ($Parents) = &GetEdges($FirstRev, "parents");
  print "PARENTS:\n\t", join("\n\t", @{$Parents}), "\n";

  Shell("hg qpop -a", "Reset the sequence from the start");

  die "First Rev ${$FirstRev}{rev} has multiple parents\n" .
    "You need to specify the exact parent rev in order for this to work \n" .
    "For example, you might want to do\n" .
    "1. $PROGRAM_NAME -Log '-r${$FirstRev}{rev}' # get the parent revs\n".
    "2. decide on which parent to use, then call \n" .
    "3. hg export --switch-parent -r ${$FirstRev}{rev} >/tmp/foo/a.patch\n" .
    "4. ${PROGRAM_NAME} -Init -patchdir /tmp/foo\n" .
    "Or pass in a valid -FirstParent=REV\n"
      if ($#{$Parents} != 0 && ($FirstParent eq ''));
  if ($FirstParent ne '') {
    my %ParentRev = &GetHgLog($FirstParent);
    $FirstParent = $ParentRev{'rev'} # get the canonical rev for the Parent
  }
  chdir ($DstRepo);
  my (@CurrSeries) = grep { chomp } Piped("hg qseries", "get existing qseries");
  
  chdir $SrcRepo;
  my ($TmpDir); chomp ($TmpDir = &tempdir("/tmp/hgexport.XXXXX", CLEANUP => 0));
  my ($i, $idx) = ($#CurrSeries+1, sprintf("%04d", $#CurrSeries+1));
  my ($RevLog) = $Path[0];
  my ($tweak) = '';

  if ($#{$Parents} == 1) {
    if ($FirstParent eq ${$Parents}[0]) {
      $tweak = '';
    } elsif ($FirstParent eq ${$Parents}[1]) {
      $tweak = '--switch-parent';
    } else {
      die "-FirstParent=${FirstParent} does not match any parent of ${$FirstRev}{rev}\n";
    }
  }
  
  Shell("hg export -r ${$RevLog}{rev} ${tweak} -o \"${TmpDir}/%b-${idx}-%r-%H.patch\"", 
        "export initial version");

  foreach $i (1 .. $#Path) {
    $RevLog = $Path[$i];
    $idx = sprintf "%04d",$i + $Base;
    print "REVISION: ${$RevLog}{rev} ";
    my($Parents) = &GetEdges($RevLog, "parents");
    if ($#$Parents == 0) {
      print "has one parent\n";
      Shell("hg export -r ${$RevLog}{rev} -o \"${TmpDir}/%b-${idx}-%r-%H.patch\"",
            "export $i");
    } else {
      $_ = ${$Path[$i-1]}{"rev"};
      if ($_ eq ${$Parents}[0]) {
        print "has two parents, choosing the first\n";
        Shell("hg export -r ${$RevLog}{rev} -o \"${TmpDir}/%b-${idx}-%r-%H.patch\"",
              "export $i");
      } else {
        print "has two parents, choosing the second\n";
        Shell("hg export --switch-parent -r ${$RevLog}{rev} -o \"${TmpDir}/%b-${idx}-%r-%H.patch\"",
              "export $i");
      }
    }
  }
  
  @NewPatches = grep { chomp } &Piped("ls -1 ${TmpDir}/*.patch", "Get List Of New Patches");
  if ($UseTraditional) {
    print "************************************************************************\n";
    print "About to apply the patches in ${TmpDir}\n",
      "If this fails for any reason, fix the patches and call ",
     " invoke\n\t$PROGRAM_NAME -Init -RepoDir=$SrcRepo ";
    print "-PatchOptions='$PatchOptions' " if ($PatchOptions ne '');
    print "$Where " if ($Where ne '');
    print "-BaseRev='$DstBaseRev' " if ($DstBaseRev ne '');
    print "\n************************************************************************\n";
    &InitPatchQueue($PatchOptions, \@NewPatches, $DstRepo, $DstBaseRev, $Where);
  }
  
  chdir $OrigDir;
}

sub GetEdges {
  # hg nodes are relatively simple. They have at most two edges each for
  # incoming or outgoing
  
  my ($L, $k) = (@_);
  my (@R);
  $_ = $$L{$k};
  my (@x) = split(" ", $_);
  while ($#x >= 0) {
    my $y = shift @x;
    push @R, $y if (($y ne '') &&
                    ($y ne '-1:0000000000000000000000000000000000000000'));
  };
  return \ @R;
}

sub FindEditPath {
  my ($SrcRepo, $BaseRev, $EndRev) = (@_);
  my (@stk);
  # we get the canonical node id's in case the user sent in something silly
  # like a branch id
  chdir $SrcRepo;
  print "Trying to get the canonical node ID's for '$BaseRev' and '$EndRev' in '$SrcRepo'\n";
  my (%CurrRevLog) = &GetHgLog($BaseRev);
  my (%EndRevLog) =  &GetHgLog($EndRev);
  my ($CurrRev) = $CurrRevLog{"rev"};
  $EndRev = $EndRevLog{"rev"};
  print "BaseRev:$CurrRev EndRev:$EndRev\n";
  my (%Visited);
  push @stk, $CurrRev;
  my (%AllLogs);

  # do a non recursive depth first search 
  while ($#stk >= 0) {
    $CurrRev = $stk[-1];
    # We do a log lookup to get the full Nodeid because for some silly 
    # reason hg log returns the short form nodeid for the children, but reports
    # the long form nodeid for the parents. So we canonicalize them
    my (%Log) = &GetHgLog($CurrRev);
    print "Considering Node $Log{rev}\n";
    $stk[-1] = $CurrRev = $Log{"rev"}; # reset to the rev
    $AllLogs{$CurrRev} = \%Log;

    last if ($Log{"rev"} eq $EndRev);

    my $ChildRevs;
    if (! (exists($Visited{$CurrRev})) ) {
      $ChildRevs = &GetEdges(\%Log, "children");
      $Visited{$CurrRev} = $ChildRevs;
    }
    foreach (@$ChildRevs) {
      print "\tKid $_\n";
    }
    
    $ChildRevs = $Visited{$CurrRev};
    
    if ($#{$ChildRevs} >= 0) {
      $_ = shift @$ChildRevs;
      print "\tconsidering $_\n";
      push @stk, $_;
    } else {
      # we have landed on a dead revision.
      # pop stack.
      print "popping stack\n";
      pop @stk;
    }
  };
  
  return map { $AllLogs{$_} } @stk;
}



sub HgRevertClean() {
  my ($RepoDir) = @_;
  my ($CMD, $RepoRoot) =  &GetRepoRoot($RepoDir);
  chdir $RepoRoot;
  die "$RepoRoot is not a hg repo\n" if ("hg" ne $CMD);
  Shell("hg revert -a .", "");
  my (@Files) = &HgGetUnknownFiles();
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
  &HgRefreshLoop(grep { chomp } @PatchList);
}

sub HgRefreshLoop() {
  my (@PatchList) = @_;
  my ($MqPatch);
  my (@Files) = &HgGetUnknownFiles();
  if ($#Files >= 0) {
    die  "\t" . join("\t\n", @Files) .
      "\n The above untracked files are in the repo.\n" .
        "Please either PQHelper.pl -Clean or merge them somehow\n";
  }

  foreach $MqPatch (@PatchList) {
    last if ($MqPatch eq "STOP");
    chomp $MqPatch;
    print "Processing $MqPatch\n";
    Shell("hg qpush $MqPatch", "", "");
    Shell("hg qrefresh", "", "");
  }
  &TagRepo('', '', "RefreshSuccess");
  Shell("hg -R .hg/patches stat", "");
  print "Refresh Successful\n";
}

sub HgContinueRefresh {
  ## called when a HgRefreshAll has failed and a manual intervention was required
  ## the repo must be clean, esp without any .orig or -rej files
  my(@MqSeries) = grep { chomp } Piped("hg qseries");
  my (@MqApplied) = grep { chomp } Piped("hg qapplied");
  map { my($x) = shift @MqSeries;
        $x eq $_ || die "hg qapplied does not look like declared qseries!\n";
      } @MqApplied;
  &HgRefreshLoop(@MqSeries);
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




sub HgTrackPatch {
  my ($RepoDir) = @_;
  my ($CMD, $RepoRoot) =  GetRepoRoot($RepoDir);
  chdir $RepoRoot;
  my @Files = `hg stat`;
  my (@ToBeDeleted) = map { chomp; $_ = substr($_, 2) } grep { /^\!/ } @Files;
  my (@ToBeAdded) = map { chomp; $_ = substr($_, 2) }
    grep { !/(orig|rej)$/ }
    grep { /^\?/ } @Files;
  Shell("hg add ${\(join(' ', @ToBeAdded))}", "ADD These NEW FILES") if ($#ToBeAdded >= 0);
  Shell("hg remove ${\(join(' ', @ToBeDeleted))}", "FORGET THESE OLD FILES") if ($#ToBeDeleted >= 0);
}

sub GetPatchedFiles {
  my ($RepoDir) = @_;
  $RepoDir = &GetRepoRoot($RepoDir);
  my (@Patches) = grep { chomp } Piped("hg qseries");
  chdir $RepoDir;
  chdir ".hg/patches";
  my (@Files) = Piped("egrep -h '^diff ' " . join(" ", @Patches));
  print @Files;
}


chomp($_ = `pwd`);

  if (grep { /^-Clean$/ } @ARGV) {
    &HgRevertClean($_);
    &HgRevertClean("$_/.hg/patches");

  } elsif (grep { /^-Foo$/ } @ARGV) {
    my ($SrcDir, $DstDir);
    chomp($SrcDir=`pwd`);
    &GetPatchedFiles($SrcDir);
#     &ArgvHasUniqueOpt('-SrcDir', \$SrcDir) ||
#       die "Requires -SrcDir=DIR\n";
#     &ArgvHasUniqueOpt('-DstDir', \$DstDir) ||
#       die "Requires -DstDir=DIR\n";
#     &Foo($SrcDir, $DstDir);
    
  } elsif (grep { /^-Init$/ } @ARGV) {
    
    my ($PatchOptions, $PatchDir, $RepoDir, $BaseRev, $Where);
    my ($Cmd,$R1);

    &ArgvHasUniqueOpt('-PatchDir', \$PatchDir) ||
      die "Requires -PatchDir=DIR\n";

    opendir(my $dh, $PatchDir) || die "can't opendir the patch directory $PatchDir: (use -PatchDir DIR) $!";
    @PatchList = sort map { $_ = "${PatchDir}/$_" }
      grep { /\.patch$/ } grep { -f "${PatchDir}/$_" } readdir($dh);
    closedir $dh;
    
    $BaseRev='';
    &ArgvHasUniqueOpt('-BaseRev', \$BaseRev);

    $PatchOptions='';
    &ArgvHasUniqueOpt('-PatchOptions', \$PatchOptions);
    
    chomp($RepoDir = `pwd`);
    ($Cmd, $RepoDir) = &GetRepoRoot($RepoDir);
    if (! &ArgvHasUniqueOpt('-RepoDir', \$RepoDir)) {
      die "$RepoDir is not a valid Hg Repo directory. Use -RepoDir=DIR)\n" 
        if ($Cmd ne 'hg');
    }
    
    ($Cmd, $RepoDir) = &GetRepoRoot($RepoDir);
    die "-RepoDir='$RepoDir' is not a valid Hg Repo directory.\n" 
      if ($Cmd ne 'hg');

    ## &InitPatchQueue("-p2 -s", \@PatchList,  $_, "svnrev(124151)",);
    &InitPatchQueue($PatchOptions, \@PatchList, $RepoDir, $BaseRev);
    
  } elsif (grep { /^-InitFromHgExport$/ } @ARGV) {
    my ($SrcRepo, $PatchOptions, $BaseRev, $EndRev, $DstRepo, 
        $DstBaseRev, $Where, $FirstRev);
    
    chomp($SrcRepo = `pwd`);
    #$PatchOptions = "-p2 -s";
    #$BaseRev = "220";
    #$EndRev = "pnacl-sfi";
    #$DstRepo = "../../llvm/llvm-trunk";
    #$DstBaseRev = '';
    $Where = '-FromNow';
    $FirstParent = '';
    
    &ArgvHasUniqueOpt('-SrcRepo', \$SrcRepo) || die "Need SrcRepo -SrcRepo=DIR\n";
    &ArgvHasUniqueOpt('-PatchOptions', \$PatchOptions);

    &ArgvHasUniqueOpt('-DstRepo', \$DstRepo) ||
      die   "Need a destination repo dir (use -DstRepo DIR)\n";
    &ArgvHasUniqueOpt('-BaseRev', \$BaseRev) ||
      die "Need a Base Revision (-BaseRev=REV)\n";
    $EndRev = $BaseRev;    
    &ArgvHasUniqueOpt('-EndRev', \$EndRev) ||
      print "Need a End Revision (Using -EndRev=$BaseRev)\n";
    &ArgvHasUniqueOpt('-DstBaseRev', \$DstBaseRev);

    $Where = '-FromStart' if (&ArgvHasFlag('-FromStart'));
    $Where = '-FromEnd' if (&ArgvHasFlag('-FromEnd'));

    &ArgvHasUniqueOpt('-FirstParent', \$FirstParent);
    
    &InitPatchQueueFromHgExport($SrcRepo, $PatchOptions, $BaseRev, $EndRev,
                                $DstRepo, $DstBaseRev, $Where, $FirstParent);
  } elsif (grep { /^-Track$/ } @ARGV) {
    &HgTrackPatch($_);
  } elsif (grep { /^(-Refresh|-Rebase)$/ } @ARGV) {
    &HgRefreshAll($_, );
  } elsif (grep { /^-ContinueRefresh$/ } @ARGV) {
    &HgContinueRefresh($_);
  } elsif (grep { /^-PushAll$/ } @ARGV) {
    my (@MqSeries) = grep { chomp } Piped("hg qseries", "Get current qseries");
    my (@MqApplied) = grep { chomp } Piped("hg qapplied", "Get applied patches");
    map { my($x) = shift @MqSeries;
          $x eq $_ || die "hg qapplied does not look like declared qseries!\n";
        } @MqApplied;
    print "Starting import at $MqSeries[0]\n";
    &HgPushLoop(@MqSeries);
  } elsif (grep { /^-up/i } @ARGV) {
    my ($Rev);
    die "need -r\n" if (! &ArgvHasUniqueOpt('-r', \$Rev));
    my (%RevLog) = &GetHgLog($Rev);
    my ($RevName) = &GetRevName(%RevLog);
    
    &Shell("hg qpop -a", "");
    &Shell("hg -R .hg/patches up -r $RevName", "update mq");
    &Shell("hg up -r $RevLog{rev}", "update repo");
    my (@MqSeries) = grep { chomp } Piped("hg qseries", "Get current qseries");
    &HgPushLoop(@MqSeries);

  } elsif (grep { /^-Merge3$/ } @ARGV) {
    my (@Rejected) = grep { /\.rej$/ }
      grep { chomp } Piped("hg stat -un", "Get list of rejected chunks");
    my ($OrigRev, $CurrRev);
    my ($RepoDir)= '';
    chomp($RepoDir=`pwd`);

    if (! &ArgvHasUniqueOpt('-OrigRev', \$OrigRev)) {
      chdir ".hg/patches";
      my(%MQRev) = &GetHgLog('');
      my(@Branches) = split(" ", $MQRev{branches});
      my($Branch, $MqBranch);

      foreach $Branch  (@Branches) {
        $MqBranch = $Branch;
        if ($Branch =~ /^svn([0-9]+)$/) {
          $OrigRev = "svnrev($1)";         last;
        } elsif ($Branch =~ /^tag(.*)$/) {
          $OrigRev = $1;         last;
        } elsif ($Branch =~ /^rev(.*)$/) {
          $OrigRev = $1; last;
        }
      }
      print "Considering -OrigRev $OrigRev (discovered from mq repo)\n";
      chdir $RepoDir;
      %MQRev = &GetHgLog($OrigRev);
      (&GetRevName(%MQRev) eq $MqBranch)
        || die "requires -OrigRev=REV (is: $OrigRev vs $MqBranch - the original rev from which the rebase started)\n";
    }
    chdir $RepoDir;
    my (%QParent) = &GetHgLog('qparent');
    $CurrRev = &GetRevName(%QParent);
    $CurrRev ne '' || &ArgvHasUniqueOpt('-CurrRev', \$CurrRev)
      || die "Need a valid qparent tag. -CurrRev=REV\n";
    &Merge3($RepoDir, $OrigRev, $QParent{rev}, @Rejected);

  } elsif (grep { /^-MergeOneFile$/ } @ARGV)  {
    my ($OrigRev, $CurrRev);
    my ($RepoDir)= '';
    my ($TryAlt) = 0;
    chomp($RepoDir=`pwd`);

    $TryAlt = &ArgvHasFlag('-TryAlt');
    print "TryAlt = $TryAlt\n";
    die "Requires -OrigRev=REV\n" if (! &ArgvHasUniqueOpt('-OrigRev', \$OrigRev));
    
    my(%OrigRevLog) = &GetHgLog($OrigRev);
    my ($OrigRevName) = &GetRevName(%OrigRevLog);
    my (%QParentLog) = &GetHgLog('qparent');

    my ($CurrRevName) = &GetRevName(%QParentLog);
    my (@Targets) = grep { -f $_ && -r $_ } grep { ! /^-.*$/ } @ARGV;
    my ($TmpDir); chomp ($TmpDir = &tempdir("/tmp/hgmergeone.${OrigRevName}.${CurrRevName}.XXXXX", CLEANUP => 0));
    foreach $Target (@Targets) {
      if ($TryAlt) {
        print "Trying alternate merge3\n"
        &MergeOneFileAlt($RepoDir, \%OrigRevLog, \%QParentLog, $Target, $TmpDir);
      } else {
        print "Trying original merge3\n"
        &MergeOneFile($RepoDir, \%OrigRevLog, \%QParentLog, $Target, $TmpDir);
      }
    }
  } elsif (grep { /^-CommitRefresh$/ } @ARGV) {
    my ($Rev) = '';
    my ($RepoRoot) = $_;
    if (! &ArgvHasUniqueOpt('-BaseRev', \$Rev)) {
      print "No -BaseRev specified. Seeing if rev qparent exists..\n";
      my %Log = &GetHgLog('qparent');

      $Rev = $Log{rev};
    }
    &HgCommitMqRefresh($RepoRoot, $Rev);
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
      &MergePatchHeader($File, "${File}.stripped", "${File}.stripped");
    }
  } elsif (grep { /^-StripAllWhiteSpace$/ } @ARGV) {
    my (@Patches) = grep { !/^-\w+/ } @ARGV;

    print "Processing:\n\t", join("\n\t",@Patches), "\n" if ($#Patches >= 0);
    for $File (@Patches) {
      open (my $Fh, "$File") || die "Unable to open patch '$File' for reading\n";
      my (@Lines) = <$Fh>;
      close $Fh;
      open ($Fh, ">${File}.stripped") || die "Unable to create '${File}.stripped'\n";
      &ProcessPatch(\&AdjustAllSubchunkHeaders, $Fh,
                    &ProcessPatch(\&StripWhiteSpace, '',
                                  &ProcessPatch(\&StripAllWhiteSpace, '', @Lines)));
      close($Fh);
      &MergePatchHeader($File, "${File}.stripped", "${File}.stripped");
    }
  } elsif (grep { /^-ViewDiff$/ } @ARGV) {
    my($DiffLevel) = 1;
    &ArgvHasUniqueOpt('-DiffLevel', \$DiffLevel);
    my (@Patches) = grep { !/^-\w+/ } @ARGV;
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
  } elsif (grep { /^-Log$/ } @ARGV) {
    my (@Revs) = &ArgvHasOpt('-r');
    my ($RepoDir) = '';
    if (&ArgvHasUniqueOpt('-R', \$RepoDir)) {
      print "Using dir $RepoDir\n";
      chdir $RepoDir;
    }    
    my (%Rtn, $Rev);

    if ($#Revs >= 0) {
      foreach $Rev (@Revs) {
        ##$_ = substr($_,2);
        print "Trying REV $Rev\n";
        %Rtn = &GetHgLog($Rev);
        &WriteLog(\ %Rtn);
      }
    } else {
      %Rtn = &GetHgLog('');
      &WriteLog(\ %Rtn);
    }
  } else {
    print "-Clean (Clean and Revert) or -I (Init) or -T (track) or -Refresh\n";
    print "-InitFromHgExport\n" .
      "  Requires the following Arguments\n" . 
      "   -SrcRepo=DIR - directory of the repo to pull from (defaults to cwd)\n" .
      "   -PatchOptions=CMD - (defaults to '-p2 -s')\n" . 
      "   -BaseRev=REV  - base revision to start extracting patches from \n" .
      "   -EndRev=REV   - last revision to pull \n" .
      "   -DstRepo=DIR \n" . 
      "   -DstBaseRev=REV  (defaults to current revision)\n" .
      "    -FromNow (leave mq alone) -FromEnd (add new patches at end) -FromStart (add new patches at start)\n".
      "   -FirstParent=REV - in case the first rev has 2 parents, use this to generate the hg export.\n" .
      "   \n";
    print "-Track\n";

    print "-Refresh/-Rebase\n" .
      "  attempts to start a new rebase operation on the current revision\n\n" .
        "  If the automated rebase fails, run the following\n";
    print "-PushAll\n" .
      "  push all patches, stop at end or right before the special STOP patch\n";
    print "-Merge3\n" .
      "  -OrigRev=REV\n" .
      "  Find all .rej hunks and do a -MergeOneFile -OrigRev=REV FILE for all of them\n".
      "  each of the FILES. You will also likely need a -OrigRev argument\n" .
      " \n";
    print "-MergeOneFile  -OrigRev=REV  FILES ...\n" .
      "  -TryAlt (Try alternate merge strategy)\n" .
      "  Merge3 all listed files one at a time\n" .
      "  The current set of applied patches must have at least one chunk against each file\n" .
      "  The three revs being merged will be FILE.OrigRev+{all but last patch} FILE.OrigRev+{all patches} + FILE.CurrRev\n".
      " \n";

    print "-ContinueRefresh\n" .
      " Attempts to continue the refresh operation\n";
    print "-CommitRefresh\n" .
      "  -BaseRev=REV\n";

    print "-Log (-rREV) (-R RepoDir) \n";
    print "-Clean -- be careful of files hidden from view via .hgignore\n";
    print "\n";
    print "-StripAllWhiteSpace FILES...\n" .
     "  Removes all isolated whitespace diffs i.e. not whitespace diffs that are not contiguous\n". 
     "  with real diffs. Uses the DiffLevel argument\n";

    print "-ViewDiff -DiffLevel=NUM PatchesOrCommands)... \n" .
     "  Optional DiffLevel argument:\n" . 
     "  -DiffLevel must be a positive integer (1 for main diff, 2 for diff of a diff ...) \n" .
     "  where 1 is a single diff, 2 is a diff of a diff, 3 is a diff or a diff of a diff..\n" .
     "  -DiffLevel > 1 is necessary to discern what happens if your change is to a patch file." .
     "  -ViewDiff smartly ignores changes to nested context lines.\n" .
     "  For example: -ViewDiff -DiffLevel=2 'diff -u A.patch B.patch'" .
     "   examines the lines resulting from diff -u A.patch B.patch | egrep '^[+-]{2}' | egrep -v '^[+-]{2}(\+\+|--) '\n";
  }

## first bad revision 23197
