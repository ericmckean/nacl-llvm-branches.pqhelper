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

my ($CROSS_TARGET_ARM)   =qw(arm-none-linux-gnueabi);
my ($CROSS_TARGET_X86_32)=qw(i686-none-linux-gnu);
my ($CROSS_TARGET_X86_64)=qw(x86_64-none-linux-gnu);

print "*********************************\n";
print "This test is for llvm:$LLVMRev  llvm-gcc:($LLVMGccRev)\n";

my ($DoPart1, $DoLLVM, $DoGcc, $DoTest) = (0, 1, 1, 1);

if ($DoPart1) {
  &Shell("./tools/llvm/utman.sh clean-install", "");
  &Shell("./tools/llvm/utman.sh clean-logs", "");
  &Shell("./tools/llvm/utman.sh binutils-arm", "");
}

if ($DoLLVM) {
  &Shell("./tools/llvm/utman.sh llvm-clean", "LLVM clean");
  &Shell("./tools/llvm/utman.sh llvm", "LLVM");
  &Shell("./tools/llvm/utman.sh driver", "");
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
}
if ($DoTest) {
  &Shell("./tools/llvm/utman-test.sh test-all", "");
}

print "SUCCESS WITH REV $LLVMRev\n";
print "Now saving the artifacts\n";

#&Shell("./save-test-artifacts.pl llvm-${LLVMRev}-gcc-${LLVMGccRev}");

#&TagRepo($LLVMRepo, $LLVMLog{rev}, "TestAllPassed");
#&TagRepo($LLVMGccRepo, $LLVMGccLog{rev}, "TestAllPassed");

exit(0);
