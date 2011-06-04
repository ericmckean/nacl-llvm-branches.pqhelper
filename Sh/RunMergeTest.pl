#!/usr/bin/perl
# -*- perl -*-


use File::Basename;
use English;
use Cwd;

my ($file, $path) = fileparse(Cwd::abs_path($PROGRAM_NAME));
push @INC, $path;

require RepoHelper || die "Install Error. Unable to find RepoHelper.pm\n";
print "$EXECUTABLE_NAME $PROGRAM_NAME ", Cwd::abs_path($PROGRAM_NAME), "\n";
import RepoHelper;

my @dirs = grep { chomp } Piped("find scons-out/ -type d -name tests", "Find artifact dirs");


foreach (@dirs) {
  Shell("rm -rf $_", "clean");
}
my $NaCl = `pwd`; chomp $NaCl;

chdir "hg/llvm/llvm-trunk";
$_ = `pwd`; chomp;
Shell("hg qpop -a", "find base SVN rev");
my (%Log) = &GetHgLog('');
Shell("hg qpush -a", "Push current set og patchs");
chdir $NaCl;

$Rev = "svn${Log{svn}}";
print "*********************************\n";
print "This test is for $Rev\n";
Shell("./tools/llvm/utman.sh llvm-clean", "LLVM clean");
Shell("./tools/llvm/utman.sh llvm", "LLVM");
Shell("./tools/llvm/utman.sh driver", "");
Shell("./tools/llvm/utman-test.sh test-all", "");

print "SUCCESS WITH REV $Rev\n";
print "Now saving the artifacts\n";
Shell("./save-test-artifacts.pl $Rev");
exit(0);
