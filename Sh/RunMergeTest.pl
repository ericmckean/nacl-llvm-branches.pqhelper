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

&SetRevNameMod('');

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

my (%TestArray) = 
  map { $_ => 1 } qw(x8664 x8664pic x8632 x8632pic arm armpic);
print join(" ", keys %TestArray), "\n";
my $RUN_ALL_TESTS = keys %TestArray;


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
my (@Part1Time, @LLVMTime, @GccTime, @TestCompileTime, @TestRunTime, @SpecTime);
my ($DoPart1, $DoLLVM, $DoGcc, $DoTest, $DoSpec, $TagSuccess) = (1, 1, 1, 1, 1, 0);

$DoPart1 = 0 if (grep { /^-SkipPart1$/i } @ARGV);
$DoLLVM = 0 if (grep { /^-SkipLLVM$/i } @ARGV);
$DoGcc  = 0 if (grep { /^-SkipGCC$/i  } @ARGV);
$DoTest = 0 if (grep { /^-SkipTest$/i } @ARGV);
$DoSpec = 0 if (grep { /^-SkipSpec$/i } @ARGV);
my (@SkippedTests);

push @SkippedTests, grep { /^x86/ } keys %TestArray if (grep { /^-SkipX86$/i } @ARGV);
push @SkippedTests, grep { /^x8664/ } keys %TestArray if (grep { /^-SkipX8664$/i } @ARGV);
push @SkippedTests, grep { /^x8632/ } keys %TestArray if (grep { /^-SkipX8632$/i } @ARGV);
push @SkippedTests, grep { /^arm/ } keys %TestArray if (grep { /^-SkipARM$/i } @ARGV);
push @SkippedTests, grep { /pic$/ } keys %TestArray if (grep { /^-SkipPIC$/i } @ARGV);
if ($#SkippedTests >= 0) {
  @DeletedTests = delete @TestArray{@SkippedTests};
  print "Skipping the following tests: ", join(" ", @SkippedTests), "\n";
  print "Running the following tests: ", join(" ", keys(%TestArray)), "\n";
} else {
  my $x = keys(%TestArray);
  print "Running all tests : $RUN_ALL_TESTS out of $x\n";
}

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
  push @Part1Time, "Part 1";
  push @Part1Time, time;
  &Shell("./tools/llvm/utman.sh check-for-trusted", "");
  &Shell("./tools/llvm/utman.sh clean-install", "");
  &Shell("./tools/llvm/utman.sh clean-logs", "");
  &Shell("./tools/llvm/utman.sh binutils-arm", "");
  push @Part1Time, time;
  &ReportTime(@Part1Time);
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

##$Gold1 = "./toolchain/pnacl_linux_x86_64/arm-none-linux-gnueabi/lib/LLVMgold.so";

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
  if (0) {

    push @TestCompileTime, "Test Compilation Time";
    push @TestCompileTime, time;
    my ($J8) = '-j8';
    &Shell("./scons platform=x86-64 MODE=nacl,opt-host bitcode=1 ${J8}", "");
    &Shell("./scons platform=x86-32 MODE=nacl,opt-host bitcode=1 ${J8}", "");
    &Shell("./scons platform=arm    MODE=nacl,opt-host bitcode=1 ${J8}", "");

    &Shell("./scons platform=x86-64 MODE=nacl,opt-host bitcode=1 nacl_pic=1  ${J8}", "");
    &Shell("./scons platform=x86-32 MODE=nacl,opt-host bitcode=1 nacl_pic=1  ${J8}", "");
    &Shell("./scons platform=arm    MODE=nacl,opt-host bitcode=1 nacl_pic=1  ${J8}", "");
    push @TestCompileTime, time;
    &ReportTime(@TestCompileTime);

    &TagRepo($LLVMRepo, $LLVMLog{rev}, "TestCompileSuccess", "y") if ($TagSuccess);
    &TagRepo($LLVMGccRepo, $LLVMGccLog{rev}, "TestCompileSuccess", "y") if ($TagSuccess);
    print "**********************************************************************\n" .
      "DONE WITH BUILD\n***********************************************************\n";

    push @TestRunTime, "Test Run Time";
    push @TestRunTime, time;

    &Shell("./scons platform=x86-64 MODE=nacl,opt-host bitcode=1 ${J8} smoke_tests", "");
    &Shell("./scons platform=x86-32 MODE=nacl,opt-host bitcode=1 ${J8} smoke_tests", "");
    &Shell("./scons platform=arm    MODE=nacl,opt-host bitcode=1 ${J8} smoke_tests", "");

    &Shell("./scons platform=x86-64 MODE=nacl,opt-host bitcode=1 nacl_pic=1 ${J8} smoke_tests", "");
    &Shell("./scons platform=x86-32 MODE=nacl,opt-host bitcode=1 nacl_pic=1 ${J8} smoke_tests", "");
    &Shell("./scons platform=arm    MODE=nacl,opt-host bitcode=1 nacl_pic=1 ${J8} smoke_tests", "");
    push @TestRunTime, time;
    &ReportTime(@TestRunTime);
  } else {
    push @TestRunTime, "Test Run Time";
    push @TestRunTime, time;
    my $x = keys %TestArray;
    if ($x == $RUN_ALL_TESTS) {
      &Shell("./tools/llvm/utman-test.sh test-all", "");
    } else {
      &Shell("./tools/llvm/utman-test.sh test-x86-64", "") if (exists $TestArray{x8664});      
      &Shell("./tools/llvm/utman-test.sh test-x86-64-pic", "") if (exists  $TestArray{x8664pic});
      &Shell("./tools/llvm/utman-test.sh test-x86-32", "") if (exists  $TestArray{x8632});
      &Shell("./tools/llvm/utman-test.sh test-x86-32-pic", "") if (exists  $TestArray{x8632pic});      
      &Shell("./tools/llvm/utman-test.sh test-arm", "")   if (exists  $TestArray{arm});
      &Shell("./tools/llvm/utman-test.sh test-arm-pic", "") if (exists  $TestArray{armpic});
    }
    push @TestRunTime, time;
    &ReportTime(@TestRunTime);
  }
}

{
  push @SpecTime, "Spec2K run time";
  push @SpecTime, time;
  my ($SETUP);
  my ($SPEC_TESTS) = qw(176.gcc);
  my ($OFFICIAL) = `(cd ~/Work/cpu2000-redhat64-ia32/; pwd)`;
  chomp $OFFICIAL;
  my @SpecSetUps = qw (SetupPnaclX8664Opt SetupPnaclArmOpt);
  @SpecSetUps = grep { ! /x86/i } @SpecSetUps if (grep { /^-SkipX86/i } @ARGV );
  @SpecSetUps = grep { ! /arm/i } @SpecSetUps if (grep { /^-Skiparm/i } @ARGV );
  print "Running the following SPEC setups ", join(" ", @SpecSetUps), "\n";

  if ($DoSpec) { 
    for $SETUP qw(@SpecSetUps) { 
      &Shell("(cd tests/spec2k; ./run_all.sh CleanBenchmarks ${SPEC_TESTS})", "clean gcc spec2k");
      &Shell("(cd tests/spec2k; ./run_all.sh PopulateFromSpecHarness ${OFFICIAL} ${SPEC_TESTS})", "clean gcc spec2k");
      &Shell("(cd tests/spec2k; ./run_all.sh BuildAndRunBenchmarks  ${SETUP} ${SPEC_TESTS})", "clean gcc spec2k");
    }
    push @SpecTime, time;
    &ReportTime(@SpecTime);
  }
}

if ($DoTest && $DoSpec) {
  print "SUCCESS WITH REV $LLVMRev\n";
  print "Now saving the artifacts\n";


  &Shell("save-test-artifacts.pl $CurrRevTxt");


  &TagRepo($LLVMRepo, $LLVMLog{rev}, "TestAllPassed");
  &TagRepo($LLVMGccRepo, $LLVMGccLog{rev}, "TestAllPassed");
}

exit(0);
