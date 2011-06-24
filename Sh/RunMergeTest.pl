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
my (@StartTime) = time;
my (@Part1Time, @LLVMTime, @GccTime, @TestCompileTime, @TestRunTime);
my ($DoPart1, $DoLLVM, $DoGcc, $DoTest, $TagSuccess) = (0, 1, 1, 1, 0);

$DoLLVM = 0 if (grep { /^-SkipLLVM$/i } @ARGV);
$DoGcc  = 0 if (grep { /^-SkipGCC$/i  } @ARGV);
$DoTest = 0 if (grep { /^-SkipTest$/i } @ARGV);

$TagSuccess = 1 if (grep { /^-TagSuccess$/ } @ARGV);

sub ReportTime {
  my (@Times) = @_;
  my $Message = shift @Times;
  print "*******************************************************************\n";
  print "$Message\n";
  print $Times[1] - $Times[0], " seconds\n";
  print "*******************************************************************\n";
}

if ($DoPart1) {
  push @Part1Time, time;
  &Shell("./tools/llvm/utman.sh clean-install", "");
  &Shell("./tools/llvm/utman.sh clean-logs", "");
  &Shell("./tools/llvm/utman.sh binutils-arm", "");
  push @Part1Time, time;
}

if ($DoLLVM) {
  push @LLVMTime, "LLVM Compile Time";
  push @LLVMTime, time;
  &Shell("./tools/llvm/utman.sh llvm-clean", "LLVM clean");
  &Shell("./tools/llvm/utman.sh llvm", "LLVM");
  &Shell("./tools/llvm/utman.sh driver", "");
  push @LLVMTime, time;
  &ReportTime(@LLVMTime);
  &TagRepo($LLVMRepo, $LLVMLog{rev}, "CompileSuccess", "y") if ($TagSuccess);
}
if ($DoGcc) {
  push @GccTime, "llvm-gcc compilation time"; 
  push @GccTime, time;
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
  push @GccTime, time;
  &ReportTime(@GccTime);
  &TagRepo($LLVMGccRepo, $LLVMGccLog{rev}, "CompileSuccess", "y") if ($TagSuccess);
}

if ($DoTest) {
  push @TestCompileTime, "Test Compilation Time";
  push @TestCompileTime, time;
  &Shell("./scons platform=x86-64 MODE=nacl,opt-host bitcode=1 -j8", "");
  &Shell("./scons platform=x86-32 MODE=nacl,opt-host bitcode=1  -j8", "");
  &Shell("./scons platform=arm MODE=nacl,opt-host bitcode=1  -j8", "");

  &Shell("./scons platform=x86-64 MODE=nacl,opt-host bitcode=1 nacl_pic=1  -j8", "");
  &Shell("./scons platform=x86-32 MODE=nacl,opt-host bitcode=1 nacl_pic=1  -j8", "");
  &Shell("./scons platform=arm MODE=nacl,opt-host bitcode=1 nacl_pic=1  -j8");
  push @TestCompileTime, time;
  &ReportTime(@TestCompileTime);

  &TagRepo($LLVMRepo, $LLVMLog{rev}, "TestCompileSuccess", "y") if ($TagSuccess);
  &TagRepo($LLVMGccRepo, $LLVMGccLog{rev}, "TestCompileSuccess", "y") if ($TagSuccess);
  print "**********************************************************************\n" .
    "DONE WITH BUILD\n***********************************************************\n";

  push @TestRunTime, "Test Run Time";
  push @TestRunTime, time;
  &Shell("./scons platform=x86-64 MODE=nacl,opt-host bitcode=1  -j8", "");
  &Shell("./scons platform=x86-32 MODE=nacl,opt-host bitcode=1  -j8", "");
  &Shell("./scons platform=arm MODE=nacl,opt-host bitcode=1 -j8", "");

  &Shell("./scons platform=x86-64 MODE=nacl,opt-host bitcode=1 nacl_pic=1 -j8 smoke_tests", "");
  &Shell("./scons platform=x86-32 MODE=nacl,opt-host bitcode=1 nacl_pic=1 -j8  smoke_tests", "");
  &Shell("./scons platform=arm MODE=nacl,opt-host bitcode=1 nacl_pic=1 -j8 smoke_tests", "");
  &ReportTime(@TestRunTime);
  push @TestRunTime, time;

  print "SUCCESS WITH REV $LLVMRev\n";
  print "Now saving the artifacts\n";


  &Shell("./save-test-artifacts.pl $CurrRevTxt");


  &TagRepo($LLVMRepo, $LLVMLog{rev}, "TestAllPassed");
  &TagRepo($LLVMGccRepo, $LLVMGccLog{rev}, "TestAllPassed");
}

exit(0);
