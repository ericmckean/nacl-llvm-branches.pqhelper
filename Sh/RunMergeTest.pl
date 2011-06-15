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
my ($LLVMRepo, $LLVMGccRepo);

chdir "hg/llvm/llvm-trunk";
chomp($LLVMRepo = `pwd`);
Shell("hg qpop -a", "find base SVN rev");
my (%LLVMLog) = &GetHgLog('');
Shell("hg qpush -a", "Push current set of patchs");
my($LLVMRev) = &GetRevName(%LLVMLog);

chdir $NaCl;
chdir "hg/llvm-gcc/llvm-gcc-4.2";
chomp($LLVMGccRepo = `pwd`);
Shell("hg qpop -a", "find base SVN rev for llvm-gcc");
my (%LLVMGccLog) = &GetHgLog('');
Shell("hg qpush -a", "Push current set of patches");
my($LLVMGccRev) = &GetRevName(%LLVMGccLog);


chdir $NaCl;
my @x = grep {chomp} Piped("svnversion .", "");
my $SVNVersion = $x[0];
my $CurrRevTxt= "nacl-$SVNVersion-$LLVMRev-$LLVMGccRev";

my ($CROSS_TARGET_ARM)   =qw(arm-none-linux-gnueabi);
my ($CROSS_TARGET_X86_32)=qw(i686-none-linux-gnu);
my ($CROSS_TARGET_X86_64)=qw(x86_64-none-linux-gnu);

print "*********************************\n";
print "This test is for REVISION $CurrRevTxt\n";
my (@StartTime) = localtime(time);
my (@Part1Time, @LLVMTime, @GccTime, @TestCompileTime, @TestRunTime);
my ($DoPart1, $DoLLVM, $DoGcc, $DoTest) = (0, 1, 1, 1);

$DoLLVM = 0 if (grep { /^-SkipLLVM$/ } @ARGV);
$DoGcc  = 0 if (grep { /^-SkipGcc$/  } @ARGV);
$DoTest = 0 if (grep { /^-SkipTest$/ } @ARGV);


if ($DoPart1) {
  &Shell("./tools/llvm/utman.sh clean-install", "");
  &Shell("./tools/llvm/utman.sh clean-logs", "");
  &Shell("./tools/llvm/utman.sh binutils-arm", "");
  @Part1Time = localtime(time);
}

if ($DoLLVM) {
  &Shell("./tools/llvm/utman.sh llvm-clean", "LLVM clean");
  &Shell("./tools/llvm/utman.sh llvm", "LLVM");
  &Shell("./tools/llvm/utman.sh driver", "");
  @LLVMTime = localtime(time);
}
if ($DoGcc) {
  &Shell("./tools/llvm/utman.sh  gcc-stage1-clean ${CROSS_TARGET_ARM}", "CLEAN llvm-gcc");
  &Shell("./tools/llvm/utman.sh  gcc-stage1-clean ${CROSS_TARGET_X86_32}", "CLEAN llvm-gcc");
  &Shell("./tools/llvm/utman.sh  gcc-stage1-clean ${CROSS_TARGET_X86_64}", "CLEAN llvm-gcc");
  &Shell("./tools/llvm/utman.sh  gcc-stage1-sysroot", "");
  &Shell("./tools/llvm/utman.sh  gcc-stage1 ${CROSS_TARGET_ARM}", "");
  &Shell("./tools/llvm/utman.sh  gcc-stage1 ${CROSS_TARGET_X86_32}", "");
  &Shell("./tools/llvm/utman.sh  gcc-stage1 ${CROSS_TARGET_X86_64}", "");
  &Shell("./tools/llvm/utman.sh  rebuild-pnacl-libs", "");
  &Shell("./tools/llvm/utman.sh misc-tools", "");
  &Shell("./tools/llvm/utman.sh  verify", "");
  @GccTime = localtime(time);
}

if ($DoTest) {
  &Shell("./scons platform=x86-64 MODE=nacl,opt-host bitcode=1 -j8", "");
  &Shell("./scons platform=x86-32 MODE=nacl,opt-host bitcode=1  -j8", "");
  &Shell("./scons platform=arm MODE=nacl,opt-host bitcode=1  -j8", "");

  &Shell("./scons platform=x86-64 MODE=nacl,opt-host bitcode=1 nacl_pic=1  -j8", "");
  &Shell("./scons platform=x86-32 MODE=nacl,opt-host bitcode=1 nacl_pic=1  -j8", "");
  &Shell("./scons platform=arm MODE=nacl,opt-host bitcode=1 nacl_pic=1  -j8");


  print "**********************************************************************\n" .
    "DONE WITH BUILD\n***********************************************************\n";

  &Shell("./scons platform=x86-64 MODE=nacl,opt-host bitcode=1  -j8", "");
  &Shell("./scons platform=x86-32 MODE=nacl,opt-host bitcode=1  -j8", "");
  &Shell("./scons platform=arm MODE=nacl,opt-host bitcode=1 -j8", "");

  &Shell("./scons platform=x86-64 MODE=nacl,opt-host bitcode=1 nacl_pic=1 -j8 smoke_tests", "");
  &Shell("./scons platform=x86-32 MODE=nacl,opt-host bitcode=1 nacl_pic=1 -j8  smoke_tests", "");
  &Shell("./scons platform=arm MODE=nacl,opt-host bitcode=1 nacl_pic=1 -j8 smoke_tests", "");

  print "SUCCESS WITH REV $LLVMRev\n";
  print "Now saving the artifacts\n";


  &Shell("./save-test-artifacts.pl $CurrRevTxt");


  &TagRepo($LLVMRepo, $LLVMLog{rev}, "TestAllPassed");
  &TagRepo($LLVMGccRepo, $LLVMGccLog{rev}, "TestAllPassed");
}

exit(0);
